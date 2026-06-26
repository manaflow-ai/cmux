public import Foundation

/// Coalescing policy for high-frequency, work-inducing follow-up attempts.
///
/// Some event-driven loops re-run expensive work (for example a synchronous
/// layout pass) once per attempt, and are driven by high-frequency signals such
/// as `NSWindow.didUpdateNotification`, which AppKit posts on every scroll tick.
/// Without a floor on attempt spacing, a burst of those signals forces the work
/// back-to-back on the main thread. This policy floors the spacing between
/// consecutive attempts at ``minInterval`` while still honoring a larger caller
/// backoff, so the surrounding runloop/display cycle can make progress between
/// attempts. See cmux issue #6790.
public struct AttemptCoalescingPolicy: Sendable, Equatable {
    /// Minimum spacing between consecutive attempts. Pick a value above one
    /// display frame so the display cycle can interleave between attempts.
    public let minInterval: TimeInterval

    /// Creates a coalescing policy.
    ///
    /// - Parameter minInterval: Minimum seconds between consecutive attempts.
    ///   Choose a value above one display frame (for example `1.0 / 30.0`) so the
    ///   display cycle can interleave and absorb pending work between attempts;
    ///   pass `0` to disable the per-frame floor and defer entirely to the
    ///   caller's backoff.
    public init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    /// The delay before the next attempt should run.
    ///
    /// Returns the larger of the caller's `backoff` and the remaining per-frame
    /// throttle (`minInterval - sinceLastAttempt`, floored at zero), so a burst
    /// of drivers cannot force back-to-back attempts while a genuine stall
    /// backoff still wins when it is larger.
    ///
    /// - Parameters:
    ///   - backoff: The caller's current backoff delay (for example an
    ///     exponential stall backoff). Pass zero when the caller has no backoff.
    ///   - sinceLastAttempt: Seconds elapsed since the previous attempt ran. A
    ///     large value (first attempt, or a long idle) disables the throttle.
    /// - Returns: The non-negative delay to wait before the next attempt.
    public func delay(backoff: TimeInterval, sinceLastAttempt: TimeInterval) -> TimeInterval {
        let throttle = max(0, minInterval - sinceLastAttempt)
        return max(backoff, throttle)
    }
}
