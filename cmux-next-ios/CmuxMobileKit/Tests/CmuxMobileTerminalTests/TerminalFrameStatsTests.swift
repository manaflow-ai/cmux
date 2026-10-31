import Testing
@testable import CmuxMobileTerminal

/// G-04: in-app frame timing, summarized per phase.
@Suite struct TerminalFrameStatsTests {
    @Test func percentilesAndHitchesPerPhase() {
        var stats = TerminalFrameStats(frameDuration: 1.0 / 120)
        let drag = TerminalFrameStats.Key(phase: "interacting", streaming: true)
        for _ in 0..<98 { stats.add(drag, interval: 1.0 / 120, workMs: 1) }
        stats.add(drag, interval: 0.025, workMs: 9)
        stats.add(drag, interval: 0.050, workMs: 20)
        let s = try! #require(stats.summary(drag))
        #expect(s.frames == 100)
        #expect(abs(s.p50Ms - 8.333) < 0.01)
        #expect(abs(s.p99Ms - 25) < 0.01)
        #expect(s.maxMs == 50)
        // 25 ms and 50 ms are over 1.5 frames (12.5 ms); 8.3 ms is not.
        #expect(s.hitches == 2)
        #expect(stats.summary(.init(phase: "following", streaming: false)) == nil)
        #expect(stats.report.hasPrefix("interacting+streaming n=100"))
    }

    @Test func nearestRank() {
        #expect(TerminalFrameStats.percentile([1, 2, 3, 4], 0.5) == 2)
        #expect(TerminalFrameStats.percentile([1, 2, 3, 4], 0.95) == 4)
        #expect(TerminalFrameStats.percentile([], 0.5) == 0)
    }
}
