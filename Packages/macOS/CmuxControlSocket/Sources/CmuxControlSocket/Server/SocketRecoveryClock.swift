/// Clock seam for the listener's recovery delays (today: the accept-source
/// resume backoff), so tests can drive the delay with virtual time instead of
/// waiting on the wall clock.
///
/// Mirrors the `FileWatchClock`/`UpdateClock` precedent: one narrow sleep
/// entry point, injected through the server initializer, defaulting to the
/// continuous clock in production.
public protocol SocketRecoveryClock: Sendable {
    /// Suspends the calling task for `milliseconds`, throwing
    /// `CancellationError` when the task is cancelled first.
    func sleep(forMilliseconds milliseconds: Int) async throws
}

/// Production ``SocketRecoveryClock`` backed by `ContinuousClock`.
public struct SystemSocketRecoveryClock: SocketRecoveryClock {
    /// Creates the system clock.
    public init() {}

    /// Sleeps on the continuous clock; cancellation propagates as
    /// `CancellationError`.
    public func sleep(forMilliseconds milliseconds: Int) async throws {
        try await ContinuousClock().sleep(for: .milliseconds(milliseconds))
    }
}
