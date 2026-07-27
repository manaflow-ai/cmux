/// Blocking subprocess execution seam for the session coordinator's SSH/SCP
/// orchestration (and the dev-only `go build` fallback).
///
/// Replaces the legacy `runProcessOverrideForTesting` static test seam with
/// constructor injection: production injects ``RemoteSessionProcessRunner``,
/// tests inject a fake that scripts each invocation. Calls BLOCK the calling
/// thread until the process exits or times out, by the same contract as the
/// legacy `runProcess` (callers run on the coordinator's serial utility
/// queue, never on the cooperative pool).
public protocol RemoteSessionProcessRunning: Sendable {
    /// Runs the request to completion and returns the captured result.
    ///
    /// - Parameters:
    ///   - request: The executable, argv, environment, stdin, and timeout.
    ///   - operation: Optional transfer-cancellation token; when it cancels,
    ///     the process is terminated and `operation.cancellationError` is
    ///     thrown.
    /// - Throws: The legacy launch-failure (`cmux.remote.process` code 1) and
    ///   timeout (code 2) errors, or `operation.cancellationError`.
    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult
}
