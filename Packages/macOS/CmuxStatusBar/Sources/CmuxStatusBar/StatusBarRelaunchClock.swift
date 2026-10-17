/// Waits out the gap between a status bar command exiting and its next start.
/// Injected so tests can step relaunches without real waits.
public protocol StatusBarRelaunchClock: Sendable {
    /// Suspends for `duration`, throwing `CancellationError` when the owning
    /// task is cancelled first.
    func sleep(for duration: Duration) async throws
}

/// The production ``StatusBarRelaunchClock``, backed by `Task.sleep`.
public struct SystemStatusBarRelaunchClock: StatusBarRelaunchClock {
    /// Creates the production clock.
    public init() {}

    /// Suspends for `duration` on the system clock.
    public func sleep(for duration: Duration) async throws {
        // Intended relaunch delay behind the injected clock seam
        // (modern-concurrency carve-out): one bounded wait per command exit,
        // cancelled with the feed's task when the command changes.
        try await Task.sleep(for: duration)
    }
}
