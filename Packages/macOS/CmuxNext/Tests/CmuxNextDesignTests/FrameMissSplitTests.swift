@testable import CmuxNextDesign
import Testing

/// `debug.frames`' missed-refresh split (``FrameMissSplit``): a 120 Hz frame due at its target is late because its
/// main work ran past the target, its commit did, or neither (the render server or the display).
struct FrameMissSplitTests {
    static let refresh = 1.0 / 120.0

    /// Frame 0 ticks at 1.000 and is due at 1.000 + one refresh; the next tick comes at `next`.
    static func split(_ turns: [(woke: Double, mainEnd: Double?, commitEnd: Double)], next: Double) -> FrameMissSplit {
        var split = FrameMissSplit()
        split.tick(timestamp: 1.0, target: 1.0 + refresh, refresh: refresh, openTurnWoke: nil)
        for turn in turns { split.turnEnded(woke: turn.woke, mainEnd: turn.mainEnd, commitEnd: turn.commitEnd) }
        split.tick(timestamp: next, target: next + refresh, refresh: refresh, openTurnWoke: nil)
        return split
    }

    @Test func mainWorkPastTheTargetIsMainLate() {
        let found = Self.split([(1.0005, 1.0200, 1.0210)], next: 1.025)
        #expect(found.counts == [.mainLate: 1])
        #expect(found.misses.first?.cause == .mainLate)
    }

    @Test func aCommitPastTheTargetIsCommitLate() {
        let found = Self.split([(1.0005, 1.0050, 1.0200)], next: 1.025)
        #expect(found.counts == [.commitLate: 1])
    }

    @Test func anIdleMainThreadAtTheTargetIsPresentedLate() {
        // The turn ended before the target; the next turn woke after it.
        let found = Self.split([(1.0005, 1.0030, 1.0040), (1.0120, 1.0130, 1.0140)], next: 1.025)
        #expect(found.counts == [.presentedLate: 1])
        let miss = found.misses.first
        #expect(miss.map { abs($0.nextTickAfterTargetMs - (1.025 - 1.0 - Self.refresh) * 1_000) < 0.001 } == true)
    }

    /// Review of #36242: the display-link tick runs inside a main turn, so a turn that woke before the deadline and still
    /// runs when the next frame ticks has not reported its end yet. It crossed the deadline with its main work running.
    @Test func aTurnStillOpenAcrossTheDeadlineIsMainLate() {
        var split = FrameMissSplit()
        split.tick(timestamp: 1.0, target: 1.0 + Self.refresh, refresh: Self.refresh, openTurnWoke: nil)
        split.tick(timestamp: 1.025, target: 1.025 + Self.refresh, refresh: Self.refresh, openTurnWoke: 1.002)
        #expect(split.counts == [.mainLate: 1])
        // A turn that woke after the deadline did not cross it: the frame was late with the main thread idle at it.
        var idle = FrameMissSplit()
        idle.tick(timestamp: 1.0, target: 1.0 + Self.refresh, refresh: Self.refresh, openTurnWoke: nil)
        idle.tick(timestamp: 1.025, target: 1.025 + Self.refresh, refresh: Self.refresh, openTurnWoke: 1.012)
        #expect(idle.counts == [.presentedLate: 1])
    }

    @Test func aFrameOnTimeIsNoMiss() {
        let found = Self.split([(1.0005, 1.0200, 1.0210)], next: 1.0 + Self.refresh)
        #expect(found.counts.isEmpty && found.misses.isEmpty)
        let report = found.report["missed_split"] as? [String: Int]
        #expect(report == ["main_late": 0, "commit_late": 0, "presented_late": 0])
    }
}
