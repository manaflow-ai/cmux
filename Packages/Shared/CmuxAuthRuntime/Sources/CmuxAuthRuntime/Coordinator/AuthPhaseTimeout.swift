import Foundation

/// Internal marker distinguishing "the deadline child fired" from errors the
/// operation itself threw (including `CancellationError` when the caller's
/// task is cancelled, which must surface as a cancellation, not a timeout).
private struct AuthPhaseDeadlineExceeded: Error {}

/// Race `operation` against a `duration` deadline on `clock`.
///
/// Structured: whichever side finishes first cancels the other, and the task
/// group joins both children before returning, so neither can outlive the
/// call. The operation must be cancellation-responsive for the bound to be
/// real (URLSession calls are; the interactive OAuth waits are made so by the
/// cancellation gates in the vendored Stack SDK).
///
/// - Parameters:
///   - phase: The phase label for timeout diagnostics.
///   - duration: The deadline.
///   - clock: The clock the deadline sleeps on (virtual in tests).
///   - log: Redacted diagnostics sink; timeouts log the phase and duration.
///   - operation: The bounded work.
/// - Returns: The operation's value when it beats the deadline.
/// - Throws: ``AuthError/timedOut`` at the deadline; otherwise rethrows the
///   operation's error (including `CancellationError` on outer cancellation).
func withAuthPhaseTimeout<T: Sendable>(
    _ phase: AuthPhase,
    duration: Duration,
    clock: any Clock<Duration>,
    log: AuthDebugLog,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await clock.sleep(for: duration, tolerance: nil)
            throw AuthPhaseDeadlineExceeded()
        }
        // Cancel the loser on every exit path; the group then joins it.
        defer { group.cancelAll() }
        do {
            guard let first = try await group.next() else {
                throw AuthError.timedOut
            }
            return first
        } catch is AuthPhaseDeadlineExceeded {
            log.log("auth.phase=\(phase.rawValue) timed out after \(duration)")
            throw AuthError.timedOut
        }
    }
}
