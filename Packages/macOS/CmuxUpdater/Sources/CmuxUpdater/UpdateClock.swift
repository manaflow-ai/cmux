/// An injectable clock for the updater's bounded, cancellable UI delays (minimum check
/// display, "no updates" auto-dismiss, ready-timeout).
///
/// Production uses ``SystemUpdateClock`` (a real `Task.sleep`); tests inject a fake that
/// returns immediately or coordinates timing, so delay-driven behavior is verified with no
/// real waiting. The delays this clock drives are *intended* delays, never a poll or a
/// "let state settle" hack.
public protocol UpdateClock: Sendable {
    /// Suspends for `duration`, throwing `CancellationError` if the surrounding task is
    /// cancelled first.
    func sleep(for duration: Duration) async throws
}

/// The production ``UpdateClock``, backed by `Task.sleep`.
public struct SystemUpdateClock: UpdateClock {
    /// Creates a system clock.
    public init() {}

    public func sleep(for duration: Duration) async throws {
        // Bounded, cancellable, intended delay behind the UpdateClock seam (policy carve-out).
        try await Task.sleep(for: duration)
    }
}
