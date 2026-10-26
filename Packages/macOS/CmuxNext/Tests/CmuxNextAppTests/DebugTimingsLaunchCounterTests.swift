@testable import CmuxNextApp
import CmuxNextLaunch
import CmuxNextSettings
import Testing

/// `debug.timings` reports the launch counters (p08-startup-007) as `launch_temperature` and
/// `launch_counters`, apart from the time marks in `launch_ms_since_process_start`, and
/// `markLaunch` feeds them from its milestones once each.
@MainActor struct DebugTimingsLaunchCounterTests {
    nonisolated struct FixedCounters: LaunchCounterSource {
        var pages: UInt64
        func pageIns() -> UInt64? { pages }
        func mainThreadCPUNanos() -> UInt64? { 187_500_000 }
    }

    nonisolated struct NoSink: LaunchValueSink {
        func writeValue(name: String, number: Double) {}
        func writeValue(name: String, label: String) {}
    }

    @Test func theTemperatureIsNullAndTheValuesEmptyUntilRead() {
        let report = DebugTimings.counterReport(LaunchCounterLog.Snapshot())
        #expect(report.temperature == .null)
        #expect(report.values == .object([:]))
    }

    @Test func theReportNamesTheTemperatureAndEachValue() {
        let log = LaunchCounterLog(reader: StartupCounterReader(source: FixedCounters(pages: 4_200)), sink: NoSink())
        log.read(atMilestone: "run_loop_start")
        log.read(atMilestone: "first_window_frame_committed")
        let report = DebugTimings.counterReport(log.snapshot)
        #expect(report.temperature == .string("cold"))
        #expect(report.values == .object([
            "launch.pageins_run_loop_start": .number(4_200),
            "launch.pageins_first_frame": .number(4_200),
            "launch.main_cpu_ms": .number(187.5),
        ]))
    }

    /// The real path: `markLaunch("run_loop_start")` reads this process's page-ins, and a
    /// repeated mark keeps the first temperature and values; no value is a time mark.
    @Test func markLaunchFeedsTheReportOnceAndKeepsValuesOutOfTheTimeMarks() throws {
        DebugTimings.markLaunch("run_loop_start")
        let first = DebugTimings.handle([:])
        let temperature = try #require(first["launch_temperature"]?.stringValue)
        #expect(StartupTemperature(rawValue: temperature) != nil)
        #expect(first["launch_counters"]?["launch.pageins_run_loop_start"] != nil)
        DebugTimings.markLaunch("run_loop_start")
        let again = DebugTimings.handle([:])
        #expect(again["launch_temperature"] == first["launch_temperature"])
        #expect(again["launch_counters"] == first["launch_counters"])
        for name in [StartupCounterReader.temperatureName, StartupCounterReader.pageInsRunLoopStartName] {
            #expect(first["launch_ms_since_process_start"]?[name] == nil)
        }
    }
}
