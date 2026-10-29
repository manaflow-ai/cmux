@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextInputCore
import CmuxNextSettings
import Testing

/// `debug.cef` section `pump` carries the input policy's counters (DC2): passes while
/// input was pending by every input target and by the bound, the holds, and one pass's p99.
@MainActor @Suite struct DebugCEFPumpReportTests {
    @Test func thePumpReportHasTheInputPolicyKeys() throws {
        var stats = CEFPumpStats()
        stats.deferredForInput = 3
        stats.passesWhileInputPending.boundExpired = 2
        stats.passTimes.record(nanos: 1_500_000)
        let report = DebugCEF.pumpReport(stats)

        #expect(report["deferred_for_input"] == .number(3))
        let passes = try #require(report["passes_while_input_pending"])
        #expect(passes["boundExpired"] == .number(2))
        #expect(passes["chromiumPage"] == .number(0))
        #expect(passes["terminal"] == .number(0))
        #expect(passes["other"] == .number(0))
        let p99 = try #require(report["pass_ms_p99"])
        #expect(p99 != .number(0), "one 1.5 ms pass was recorded")
    }

    /// split-spring --suite=cef-idle reads `early_passes`.
    @Test func thePumpReportHasEarlyPasses() {
        var stats = CEFPumpStats()
        stats.earlyPasses = 4
        #expect(DebugCEF.pumpReport(stats)["early_passes"] == .number(4))
    }

    /// The frame deadline's holds: motion-hitches.py and bench-typing.py read them
    /// next to the pass times.
    @Test func thePumpReportHasTheFrameDeadlineHolds() {
        var stats = CEFPumpStats()
        stats.frameDeadlineWaits = 5
        stats.frameInputHolds = 2
        let report = DebugCEF.pumpReport(stats)
        #expect(report["frame_deadline_waits"] == .number(5))
        #expect(report["frame_input_holds"] == .number(2))
    }
}
