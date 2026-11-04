import CmuxNextWakeups
import Testing
@testable import CmuxNextDaemon

/// P0 2026-10-30, lead decision (R-L4): a keyed creation waiting through late replies re-sends only to repair a lost
/// request, spaced by full-jitter exponential backoff capped at 30 s, never at the fixed reply deadline (a hung
/// daemon must get no retry storm).
struct LateReplyBackoffTests {
    @Test func fullJitterDrawsBelowTheCappedExponentialBase() {
        var top = Backoff.fullJitter(initial: .seconds(1), maximum: .seconds(30), random: { 0.999_999 })
        let bases = (0..<8).map { _ in top.next() }
        #expect(bases.map { Int($0.components.seconds) } == [0, 1, 3, 7, 15, 29, 29, 29], "\(bases)")
        var bottom = Backoff.fullJitter(initial: .seconds(1), maximum: .seconds(30), random: { 0 })
        #expect((0..<5).allSatisfy { _ in bottom.next() == .zero }, "full jitter may re-send at once")
    }

    @Test func lateRepliesAreSpacedByCappedFullJitter() {
        let backoff = DaemonConnection.lateReplyBackoff()
        #expect(backoff.full)
        #expect(backoff.initial == .seconds(1))
        #expect(backoff.maximum == .seconds(30))
    }
}
