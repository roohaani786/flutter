// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show Encoding, json;
import 'dart:io';

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:http/http.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'task_result.dart';
import 'utils.dart';

typedef ProcessRunSync = ProcessResult Function(
  String,
  List<String>, {
  Map<String, String>? environment,
  bool includeParentEnvironment,
  bool runInShell,
  Encoding? stderrEncoding,
  Encoding? stdoutEncoding,
  String? workingDirectory,
});

/// Class for test runner to interact with Flutter's infrastructure service, Cocoon.
///
/// Cocoon assigns bots to run these devicelab tasks on real devices.
/// To retrieve these results, the test runner needs to send results back so the database can be updated.
class Cocoon {
  Cocoon({
    String? serviceAccountTokenPath,
    @visibleForTesting Client? httpClient,
    @visibleForTesting this.fs = const LocalFileSystem(),
    @visibleForTesting this.processRunSync = Process.runSync,
    @visibleForTesting this.requestRetryLimit = 5,
  }) : _httpClient = AuthenticatedCocoonClient(serviceAccountTokenPath, httpClient: httpClient, filesystem: fs);

  /// Client to make http requests to Cocoon.
  final AuthenticatedCocoonClient _httpClient;

  final ProcessRunSync processRunSync;

  /// Url used to send results to.
  static const String baseCocoonApiUrl = 'https://flutter-dashboard.appspot.com/api';

  /// Underlying [FileSystem] to use.
  final FileSystem fs;

  static final Logger logger = Logger('CocoonClient');

  @visibleForTesting
  final int requestRetryLimit;

  String get commitSha => _commitSha ?? _readCommitSha();
  String? _commitSha;

  /// Parse the local repo for the current running commit.
  String _readCommitSha() {
    final ProcessResult result = processRunSync('git', <String>['rev-parse', 'HEAD']);
    if (result.exitCode != 0) {
      throw CocoonException(result.stderr as String);
    }

    return _commitSha = result.stdout as String;
  }

  /// Upload the JSON results in [resultsPath] to Cocoon.
  ///
  /// Flutter infrastructure's workflow is:
  /// 1. Run DeviceLab test, writing results to a known path
  /// 2. Request service account token from luci auth (valid for at least 3 minutes)
  /// 3. Upload results from (1) to Cocoon
  Future<void> sendResultsPath(String resultsPath) async {
    final File resultFile = fs.file(resultsPath);
    final Map<String, dynamic> resultsJson = json.decode(await resultFile.readAsString()) as Map<String, dynamic>;
    await _sendUpdateTaskRequest(resultsJson);
  }

  /// Send [TaskResult] to Cocoon.
  // TODO(chillers): Remove when sendResultsPath is used in prod. https://github.com/flutter/flutter/issues/72457
  Future<void> sendTaskResult({
    required String builderName,
    required TaskResult result,
    required String gitBranch,
  }) async {
    assert(builderName != null);
    assert(gitBranch != null);
    assert(result != null);

    // Skip logging on test runs
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((LogRecord rec) {
      print('${rec.level.name}: ${rec.time}: ${rec.message}');
    });

    final Map<String, dynamic> updateRequest = _constructUpdateRequest(
      gitBranch: gitBranch,
      builderName: builderName,
      result: result,
    );
    await _sendUpdateTaskRequest(updateRequest);
  }

  /// Write the given parameters into an update task request and store the JSON in [resultsPath].
  Future<void> writeTaskResultToFile({
    required String builderName,
    required String gitBranch,
    required TaskResult result,
    required String resultsPath,
  }) async {
    assert(builderName != null);
    assert(gitBranch != null);
    assert(result != null);
    assert(resultsPath != null);

    final Map<String, dynamic> updateRequest = _constructUpdateRequest(
      gitBranch: gitBranch,
      builderName: builderName,
      result: result,
    );
    final File resultFile = fs.file(resultsPath);
    if (resultFile.existsSync()) {
      resultFile.deleteSync();
    }
    logger.fine('Writing results: ${json.encode(updateRequest)}');
    resultFile.createSync();
    resultFile.writeAsStringSync(json.encode(updateRequest));
  }

  Map<String, dynamic> _constructUpdateRequest({
    String? builderName,
    required TaskResult result,
    required String gitBranch,
  }) {
    final Map<String, dynamic> updateRequest = <String, dynamic>{
      'CommitBranch': gitBranch,
      'CommitSha': commitSha,
      'BuilderName': builderName,
      'NewStatus': result.succeeded ? 'Succeeded' : 'Failed',
    };
    logger.fine('Update request: $updateRequest');

    // Make a copy of result data because we may alter it for validation below.
    updateRequest['ResultData'] = result.data;

    final List<String> validScoreKeys = <String>[];
    if (result.benchmarkScoreKeys != null) {
      for (final String scoreKey in result.benchmarkScoreKeys!) {
        final Object score = result.data![scoreKey] as Object;
        if (score is num) {
          // Convert all metrics to double, which provide plenty of precision
          // without having to add support for multiple numeric types in Cocoon.
          result.data![scoreKey] = score.toDouble();
          validScoreKeys.add(scoreKey);
        }
      }
    }
    updateRequest['BenchmarkScoreKeys'] = validScoreKeys;

    return updateRequest;
  }

  Future<void> _sendUpdateTaskRequest(Map<String, dynamic> postBody) async {
    final Map<String, dynamic> response = await _sendCocoonRequest('update-task-status', postBody);
    if (response['Name'] != null) {
      logger.info('Updated Cocoon with results from this task');
    } else {
      logger.info(response);
      logger.severe('Failed to updated Cocoon with results from this task');
    }
  }

  /// Make an API request to Cocoon.
  Future<Map<String, dynamic>> _sendCocoonRequest(String apiPath, [dynamic jsonData]) async {
    final Uri url = Uri.parse('$baseCocoonApiUrl/$apiPath');

    /// Retry requests to Cocoon as sometimes there are issues with the servers, such
    /// as version changes to the backend, datastore issues, or latency issues.
    final Response response = await retry(
      () => _httpClient.post(url, body: json.encode(jsonData)),
      retryIf: (Exception e) => e is SocketException || e is TimeoutException || e is ClientException,
      maxAttempts: requestRetryLimit,
    );
    return json.decode(response.body) as Map<String, dynamic>;
  }
}

/// [HttpClient] for sending authenticated requests to Cocoon.
class AuthenticatedCocoonClient extends BaseClient {
  AuthenticatedCocoonClient(
    this._serviceAccountTokenPath, {
    @visibleForTesting Client? httpClient,
    @visibleForTesting FileSystem? filesystem,
  })  : _delegate = httpClient ?? Client(),
        _fs = filesystem ?? const LocalFileSystem();

  /// Authentication token to have the ability to upload and record test results.
  ///
  /// This is intended to only be passed on automated runs on LUCI post-submit.
  final String? _serviceAccountTokenPath;

  /// Underlying [HttpClient] to send requests to.
  final Client _delegate;

  /// Underlying [FileSystem] to use.
  final FileSystem _fs;

  /// Value contained in the service account token file that can be used in http requests.
  String get serviceAccountToken => _serviceAccountToken ?? _readServiceAccountTokenFile();
  String? _serviceAccountToken;

  /// Get [serviceAccountToken] from the given service account file.
  String _readServiceAccountTokenFile() {
    return _serviceAccountToken = _fs.file(_serviceAccountTokenPath).readAsStringSync().trim();
  }

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    request.headers['Service-Account-Token'] = serviceAccountToken;
    final StreamedResponse response = await _delegate.send(request);

    if (response.statusCode != 200) {
      throw ClientException(
          'AuthenticatedClientError:\n'
          '  URI: ${request.url}\n'
          '  HTTP Status: ${response.statusCode}\n'
          '  Response body:\n'
          '${(await Response.fromStream(response)).body}',
          request.url);
    }
    return response;
  }
}

class CocoonException implements Exception {
  CocoonException(this.message) : assert(message != null);

  /// The message to show to the issuer to explain the error.
  final String message;

  @override
  String toString() => 'CocoonException: $message';
}
