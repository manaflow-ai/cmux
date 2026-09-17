/// Cancellation-aware reconnect backoff used by ``HerdrNestedTopologyClient``.
///
/// Production code waits on an explicit scheduler rather than ambient
/// ``Task.sleep`` retry loops so tests can drive reconnect with a signal and
/// cancellation still aborts the wait.
public protocol NestedReconnectScheduler: Sendable {
    /// Suspends until the next reconnect attempt should run.
    ///
    /// - Parameter backoff: Desired delay before the next attempt.
    /// - Throws: ``CancellationError`` when the surrounding task is cancelled.
    func waitForReconnectAttempt(after backoff: Duration) async throws
}

/// Default reconnect scheduler backed by ``ContinuousClock``.
public struct NestedContinuousClockReconnectScheduler: NestedReconnectScheduler {
    /// Creates a continuous-clock reconnect scheduler.
    public init() {}

    /// Waits for ``backoff`` using ``ContinuousClock/sleep(until:tolerance:)``.
    public func waitForReconnectAttempt(after backoff: Duration) async throws {
        try await ContinuousClock().sleep(for: backoff)
    }
}
