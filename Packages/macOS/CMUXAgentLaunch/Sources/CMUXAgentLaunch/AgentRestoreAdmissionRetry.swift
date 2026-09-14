import Foundation

/// Bounded retry for a retryable `busy` answer to an agent restore admission.
///
/// The app refuses admission when its ownership-sensitive process scan cannot
/// settle. Right after a relaunch several restored panes fire their
/// session-start hooks at once, so that churn is routine for a few seconds.
/// Giving up on the first answer leaves a bare shell whose binding then
/// retires, and the next relaunch has nothing to resume.
public enum AgentRestoreAdmissionRetry {
    /// Roughly 45 seconds of waiting, front-loaded so a brief storm costs
    /// little and a longer one still resolves before the user notices.
    public static let delaysSeconds: [TimeInterval] = [0.5, 1, 2, 3, 5, 5, 5, 5, 5, 5, 5]

    /// Runs `send` until it succeeds, fails with an error `isRetryable` rejects,
    /// or the delay budget is spent; the last retryable error then propagates.
    ///
    /// - Parameters:
    ///   - delays: the pause before each retry; its count bounds the retries.
    ///   - sleep: how to wait for one delay.
    ///   - onRetry: called with the zero-based retry index before each pause.
    ///   - isRetryable: whether a thrown error should be retried.
    ///   - send: the admission request.
    public static func response<Response>(
        delays: [TimeInterval] = delaysSeconds,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        onRetry: (Int) -> Void = { _ in },
        isRetryable: (Error) -> Bool,
        sending send: () throws -> Response
    ) throws -> Response {
        var attempt = 0
        while true {
            do {
                return try send()
            } catch {
                guard isRetryable(error), attempt < delays.count else { throw error }
                onRetry(attempt)
                sleep(delays[attempt])
                attempt += 1
            }
        }
    }
}
