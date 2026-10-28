import CmuxNextLaunch
import Testing

/// The first frame reads page-ins and main-thread CPU as separate values through a seam
/// (Chrome's `Startup.BrowserWindowFirstPaintHardFaultCount`); no other milestone reads anything.
/// The temperature is `LaunchSlices`'s (CmuxNextSignpostsTests/LaunchSlicesTests).
struct StartupCounterReaderTests {
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

    @Test func theFirstFrameReadsPageInsAndMainCPU() {
        let reader = StartupCounterReader(source: FixedCounters(pages: 12, cpuNanos: 187_500_000))
        #expect(reader.sample(atMilestone: "first_window_frame_committed") == [
            .init(name: "launch.pageins_first_frame", value: 12),
            .init(name: "launch.main_cpu_ms", value: 187.5),
        ])
    }

    @Test func anUnreadableFirstFrameCounterIsLeftOut() {
        let reader = StartupCounterReader(source: FixedCounters(pages: nil, cpuNanos: 2_000_000))
        #expect(reader.sample(atMilestone: StartupCounterReader.firstFrameMilestone)
            == [.init(name: "launch.main_cpu_ms", value: 2)])
        let none = StartupCounterReader(source: FixedCounters(pages: nil, cpuNanos: nil))
        #expect(none.sample(atMilestone: StartupCounterReader.firstFrameMilestone) == [])
    }

    @Test(arguments: ["main_start", "main.run", "run_loop_start", "did_finish_launching_end", "launch.temperature",
                      "first_terminal_frame"])
    func otherMilestonesReadNothing(milestone: String) {
        let reader = StartupCounterReader(source: FixedCounters(pages: 1, cpuNanos: 1, readsAllowed: false))
        #expect(reader.sample(atMilestone: milestone) == nil)
    }

    #if os(macOS)
    /// The kernel seam answers in this process on the main thread (it has run, so it has CPU time).
    @MainActor @Test func theSystemCountersReadThisProcess() {
        let counters = StartupCounterReader.SystemCounters()
        #expect(counters.pageIns() != nil)
        #expect((counters.mainThreadCPUNanos() ?? 0) > 0)
    }

    /// Off the main thread the seam reads no thread rather than the caller's own.
    @Test func theSystemCountersReadNoCPUOffTheMainThread() async {
        let cpu = await Task.detached { StartupCounterReader.SystemCounters().mainThreadCPUNanos() }.value
        #expect(cpu == nil)
    }
    #endif
}
