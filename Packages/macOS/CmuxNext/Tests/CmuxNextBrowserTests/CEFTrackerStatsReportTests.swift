@testable import CmuxNextBrowser
import Testing

/// `debug.cef` `tracker` is built from `CEFTrackerStats.reportFields` (moved out of the App's `DebugCEF`, #34252): the
/// keys pane-perf-terminal.py reads stay, each with its counter, and the times are milliseconds.
@Suite struct CEFTrackerStatsReportTests {
    @Test func everyTrackerKeyReportsItsCounterAndTimesInMilliseconds() {
        var stats = CEFTrackerStats()
        stats.clipReads = 1
        stats.occlusionReads = 2
        stats.clipBuilds = 3
        stats.clipHits = 4
        stats.clipSeconds = 0.125
        stats.geometryPosts = 6
        stats.hostedPages = 7
        stats.hostingRefused = 8
        stats.geometrySkips = 9
        #expect(stats.reportFields == [
            "clip_reads": 1, "occlusion_reads": 2, "clip_builds": 3, "clip_hits": 4, "clip_ms": 125,
            "geometry_posts": 6, "hosted_pages": 7, "hosting_refused": 8, "geometry_skips": 9,
        ])
    }
}
