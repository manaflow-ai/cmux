import Foundation
import Testing

@testable import CmuxFoundation

/// Regression coverage for cmux issue #6790: the event-driven layout follow-up
/// loop must coalesce its high-frequency drivers — chiefly
/// `NSWindow.didUpdateNotification`, which AppKit posts on every scroll tick —
/// so a burst cannot drive a synchronous full-window relayout back-to-back
/// during scroll. ``AttemptCoalescingPolicy`` is the pure policy that backs that
/// throttle; without the per-frame floor a fresh attempt landing right after the
/// previous one fires at delay 0, reproducing the per-tick relayout that caused
/// the scroll lag.
@Suite struct AttemptCoalescingPolicyTests {
    private let policy = AttemptCoalescingPolicy(minInterval: 1.0 / 30.0)

    /// A fresh attempt that lands immediately after the previous one (for example
    /// the next scroll-driven window update) must be deferred by the remaining
    /// frame budget instead of firing at delay 0.
    @Test func attemptImmediatelyAfterPreviousIsThrottledByOneFrame() {
        let delay = policy.delay(backoff: 0, sinceLastAttempt: 0)
        #expect(abs(delay - policy.minInterval) < 1e-9)
    }

    /// Once at least one interval has elapsed the throttle no longer applies, so a
    /// genuinely-spaced attempt is not artificially delayed.
    @Test func attemptAfterIntervalIsNotThrottled() {
        let delay = policy.delay(backoff: 0, sinceLastAttempt: 1.0)
        #expect(delay == 0)
    }

    /// A partially-elapsed interval is throttled by only the remaining budget.
    @Test func partiallyElapsedIntervalThrottlesByRemainder() {
        let elapsed = policy.minInterval / 3.0
        let delay = policy.delay(backoff: 0, sinceLastAttempt: elapsed)
        #expect(abs(delay - (policy.minInterval - elapsed)) < 1e-9)
    }

    /// The caller's stall backoff still wins when it exceeds the frame throttle,
    /// so existing exponential backoff for a stuck follow-up is preserved.
    @Test func backoffDominatesWhenLargerThanThrottle() {
        let backoff: TimeInterval = 0.25
        let delay = policy.delay(backoff: backoff, sinceLastAttempt: 0)
        #expect(abs(delay - backoff) < 1e-9)
    }
}
