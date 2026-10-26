/// An injectable clock for the updater's bounded, cancellable UI delays (check timeout,
/// "no updates" auto-dismiss, ready-timeout).
///
/// Production uses ``SystemUpdateClock`` (a real `Task.sleep` with leeway); tests inject a fake
/// that returns immediately or coordinates timing, so delay-driven behavior is verified with no
/// real waiting. The delays this clock drives are *intended* delays, never a poll or a
/// "let state settle" hack.
public protocol UpdateClock: Sendable {
    /// Suspends for at least `duration`, throwing `CancellationError` if the surrounding task is
    /// cancelled first.
    func sleep(for duration: Duration) async throws
}

/// The production ``UpdateClock``, backed by `Task.sleep`.
///
/// Every sleep is a flexible deadline, Chromium's default delay policy `kFlexibleNoSooner`
/// (base/task/delay_policy.h): it never fires early and may fire up to ``tolerance(for:)`` late,
/// so the kernel can fold the updater's wake into one the Mac takes anyway.
public struct SystemUpdateClock: UpdateClock {
    /// Creates a system clock.
    public init() {}

    public func sleep(for duration: Duration) async throws {
        // wakeup-allow: deadline the seam's one cancellable sleep; each caller arms a single
        // deadline, and the sleep carries the flexible leeway below.
        try await Task.sleep(for: duration, tolerance: Self.tolerance(for: duration))
    }

    /// The leeway of a `duration` sleep: Chromium's `kDefaultLeeway` of 8 ms
    /// (base/task/task_features.cc) below one second, and from one second on 10% of the delay,
    /// at most one second (Blink's 1 s wake-up budget pool, Apple's timer-coalescing guidance).
    static func tolerance(for duration: Duration) -> Duration {
        guard duration >= .seconds(1) else { return .milliseconds(8) }
        return min(duration / 10, .seconds(1))
    }
}
