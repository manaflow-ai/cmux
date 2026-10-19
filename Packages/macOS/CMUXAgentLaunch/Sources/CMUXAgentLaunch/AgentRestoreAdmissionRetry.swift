/// Bounded retry for a retryable `busy` answer to an agent restore admission.
///
/// The app refuses admission when its ownership-sensitive process scan cannot
/// settle. Right after a relaunch several restored panes fire their
/// session-start hooks at once, so that churn is routine for a few seconds.
/// Giving up on the first answer leaves a bare shell whose binding then
/// retires, and the next relaunch has nothing to resume.
public struct AgentRestoreAdmissionRetry: Sendable {
    public init() {}

    /// Roughly 45 seconds of waiting, front-loaded so a brief storm costs
    /// little and a longer one still resolves before the user notices.
    public let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(3), .seconds(5), .seconds(5), .seconds(5), .seconds(5), .seconds(5), .seconds(5), .seconds(5)]

    /// Runs `send` until it succeeds, fails with an error `isRetryable` rejects,
    /// or the delay budget is spent; the last retryable error then propagates.
    ///
    /// - Parameters:
    ///   - delays: the pause before each retry; its count bounds the retries.
    ///   - clock: the clock used for cancellable retry delays.
    ///   - onRetry: called with the zero-based retry index before each pause.
    ///   - isRetryable: whether a thrown error should be retried.
    ///   - send: the admission request.
    public func response<Response>(
        delays: [Duration]? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        onRetry: @Sendable (Int) -> Void = { _ in },
        isRetryable: @Sendable (Error) -> Bool,
        sending send: @Sendable () async throws -> Response
    ) async throws -> Response {
        let delays = delays ?? self.delays
        var attempt = 0
        while true {
            do {
                return try await send()
            } catch {
                guard isRetryable(error), attempt < delays.count else { throw error }
                onRetry(attempt)
                try await clock.sleep(for: delays[attempt])
                attempt += 1
            }
        }
    }
}
