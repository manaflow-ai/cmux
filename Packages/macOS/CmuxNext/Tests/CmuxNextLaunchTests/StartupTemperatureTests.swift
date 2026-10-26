import CmuxNextLaunch
import Testing

/// The temperature is Chrome's split of the page-ins at the run loop's start
/// (startup_metric_utils.cc `RecordHardFaultHistogram`), read through a seam;
/// the first frame reads page-ins and main-thread CPU as separate values; no
/// other milestone reads anything.
struct StartupTemperatureTests {
    /// Fixed counters; with `readsAllowed` false any read is a test failure.
    nonisolated struct FixedCounters: LaunchCounterSource {
        var pages: UInt64?
        var cpuNanos: UInt64?
        var readsAllowed = true

        func pageIns() -> UInt64? {
            if !readsAllowed { Issue.record("page-ins read outside a counter milestone") }
            return pages
        }

        func mainThreadCPUNanos() -> UInt64? {
            if !readsAllowed { Issue.record("main-thread CPU read outside a counter milestone") }
            return cpuNanos
        }
    }

    @Test func chromesConstantsAreTheStartPoint() {
        #expect(StartupTemperature.Thresholds.chrome == StartupTemperature.Thresholds(warmBelow: 5, coldFrom: 3_500))
    }

    nonisolated static let chromeBounds: [(UInt64, StartupTemperature)] = [
        (0, .warm),
        (4, .warm),
        (5, .lukewarm),
        (3_499, .lukewarm),
        (3_500, .cold),
        (40_000, .cold),
    ]

    @Test(arguments: chromeBounds)
    func chromesBoundsSplitThePageIns(pageIns: UInt64, expected: StartupTemperature) {
        #expect(StartupTemperature.Thresholds.chrome.classify(pageIns: pageIns) == expected)
    }

    @Test func anUnreadableCountIsUndetermined() {
        #expect(StartupTemperature.Thresholds.chrome.classify(pageIns: nil) == .undetermined)
        let sample = StartupCounterReader(source: FixedCounters(pages: nil, cpuNanos: nil)).sample(atMilestone: "run_loop_start")
        #expect(sample == StartupCounterReader.Sample(temperature: .undetermined, values: []))
    }

    @Test func tunedThresholdsReplaceChromes() {
        let tuned = StartupTemperature.Thresholds(warmBelow: 100, coldFrom: 2_000)
        let reader = StartupCounterReader(source: FixedCounters(pages: 99, cpuNanos: nil), thresholds: tuned)
        #expect(reader.sample(atMilestone: StartupCounterReader.runLoopStartMilestone)?.temperature == .warm)
        #expect(tuned.classify(pageIns: 2_000) == .cold)
    }

    @Test func theRunLoopStartDecidesTheTemperatureFromPageInsOnly() {
        let reader = StartupCounterReader(source: FixedCounters(pages: 4_200, cpuNanos: 9_000_000))
        let sample = reader.sample(atMilestone: "run_loop_start")
        #expect(sample == StartupCounterReader.Sample(
            temperature: .cold, values: [.init(name: "launch.pageins_run_loop_start", value: 4_200)]))
    }

    @Test func theFirstFrameReadsPageInsAndMainCPUWithoutATemperature() {
        let reader = StartupCounterReader(source: FixedCounters(pages: 12, cpuNanos: 187_500_000))
        let sample = reader.sample(atMilestone: "first_window_frame_committed")
        #expect(sample == StartupCounterReader.Sample(temperature: nil, values: [
            .init(name: "launch.pageins_first_frame", value: 12),
            .init(name: "launch.main_cpu_ms", value: 187.5),
        ]))
    }

    @Test func anUnreadableFirstFrameCounterIsLeftOut() {
        let reader = StartupCounterReader(source: FixedCounters(pages: nil, cpuNanos: 2_000_000))
        #expect(reader.sample(atMilestone: "first_window_frame_committed")?.values
            == [.init(name: "launch.main_cpu_ms", value: 2)])
    }

    @Test(arguments: ["main_start", "main.run", "did_finish_launching_end", "launch.temperature", "first_terminal_frame"])
    func otherMilestonesReadNothing(milestone: String) {
        let reader = StartupCounterReader(source: FixedCounters(pages: 1, cpuNanos: 1, readsAllowed: false))
        #expect(reader.sample(atMilestone: milestone) == nil)
    }

    #if os(macOS)
    /// The kernel seam answers in this process (it has run, so it has CPU time).
    @Test func theSystemCountersReadThisProcess() {
        let counters = StartupCounterReader.SystemCounters()
        #expect(counters.pageIns() != nil)
        #expect((counters.mainThreadCPUNanos() ?? 0) > 0)
    }
    #endif
}
