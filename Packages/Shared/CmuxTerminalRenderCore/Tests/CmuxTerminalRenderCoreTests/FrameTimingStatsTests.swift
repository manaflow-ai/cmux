import CmuxTerminalRenderCore
import Testing

@Suite struct FrameTimingStatsTests {
    @Test func percentilesAndHitches() {
        var stats = FrameTimingStats()
        var time = 0.0
        stats.frame(at: time)
        for index in 0..<100 {
            time += index == 50 ? 0.050 : 0.008
            stats.frame(at: time)
        }
        stats.parsed(1_048_576)
        #expect(stats.frames == 101)
        #expect(stats.intervals.count == 100)
        #expect(abs(stats.percentile(0.5) - 0.008) < 1e-9)
        #expect(abs(stats.percentile(1) - 0.050) < 1e-9)
        #expect(stats.hitches(budget: 1.0 / 120) == 1)
        #expect(abs(stats.duration - (99 * 0.008 + 0.050)) < 1e-9)
        let report = stats.report(workload: "flood", budget: 1.0 / 120)
        #expect(report["hitches"] == "1")
        #expect(report["p50_ms"] == "8.00")
        #expect(report["workload"] == "flood")
    }

    @Test func emptyIsZero() {
        let stats = FrameTimingStats()
        #expect(stats.percentile(0.99) == 0)
        #expect(stats.bytesPerSecond == 0)
        #expect(stats.hitches(budget: 0.016) == 0)
    }

    @Test func backwardsTimeIsIgnored() {
        var stats = FrameTimingStats()
        stats.frame(at: 1)
        stats.frame(at: 0.5)
        #expect(stats.intervals.isEmpty)
    }
}
