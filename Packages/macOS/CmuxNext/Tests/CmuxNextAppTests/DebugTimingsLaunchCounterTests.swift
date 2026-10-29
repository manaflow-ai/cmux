@testable import CmuxNextApp
import CmuxNextLaunch
import CmuxNextSettings
import Testing

/// `debug.timings` reports the first frame's launch counters as `launch_counters`,
/// apart from the time marks in `launch_ms_since_process_start`, and `markLaunch` feeds them from
/// its milestone once.
@MainActor struct DebugTimingsLaunchCounterTests {
    nonisolated struct FixedCounters: LaunchCounterSource {
        var pages: UInt64
        func pageIns() -> UInt64? { pages }
        func mainThreadCPUNanos() -> UInt64? { 187_500_000 }
    }

    nonisolated struct NoSink: LaunchValueSink {
        func writeValue(name: String, number: Double) {}
    }

    @Test func theValuesAreEmptyUntilRead() {
        #expect(DebugTimings.counterReport([]) == .object([:]))
    }

    @Test func theReportNamesEachValue() {
        let log = LaunchCounterLog(reader: StartupCounterReader(source: FixedCounters(pages: 4_200)), sink: NoSink())
        log.read(atMilestone: "first_window_frame_committed")
        #expect(DebugTimings.counterReport(log.values) == .object([
            "launch.pageins_first_frame": .number(4_200),
            "launch.main_cpu_ms": .number(187.5),
        ]))
    }

    /// The real path: `markLaunch("first_window_frame_committed")` reads this process's counters, and a
    /// repeated mark keeps the first values; no value is a time mark.
    @Test func markLaunchFeedsTheReportOnceAndKeepsValuesOutOfTheTimeMarks() {
        DebugTimings.markLaunch(StartupCounterReader.firstFrameMilestone)
        let first = DebugTimings.handle([:])
        #expect(first["launch_counters"]?[StartupCounterReader.mainCPUName] != nil)
        DebugTimings.markLaunch(StartupCounterReader.firstFrameMilestone)
        let again = DebugTimings.handle([:])
        #expect(again["launch_counters"] == first["launch_counters"])
        for name in [StartupCounterReader.pageInsFirstFrameName, StartupCounterReader.mainCPUName] {
            #expect(first["launch_ms_since_process_start"]?[name] == nil)
        }
    }
}
