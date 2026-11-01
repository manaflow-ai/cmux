import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence 2026-10-20: "I was just scrolling the sidebar and I encountered a ton of lag." A
/// scroll only moves rows that are already laid out and draws the few that come into view: each
/// frame stays inside half a 60 Hz frame (8 ms of main thread) at 500 workspaces, and a scroll
/// never lays the list out again. Prints one `SIDEBAR-SCROLL-BENCH` line per size
/// (sidebar-scroll-perf-DESIGN.md).
///
/// Each scroll pass turns back `scrollDepth` (1,800 pt, two screens) below the top, so no test's
/// frame count grows with its list: the whole 500-workspace list was about 3,600 frames a measure
/// and held the main actor past the swift-test stall watchdog (300 s with no test finished). The
/// 500 workspaces are all built and laid out; only the scrolled range is bounded.
/// `CMUX_SIDEBAR_SCROLL_BENCH=1`, like the other `*_BENCH` flags, scrolls the whole list. The time
/// limit ends a test that still runs long (`SidebarScrollBench.run` stops on cancellation), so a
/// slow runner gets a named red instead of a stalled run.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)))
struct SidebarScrollCostTests {
    nonisolated static let wholeBench = ProcessInfo.processInfo.environment["CMUX_SIDEBAR_SCROLL_BENCH"] == "1"
    /// How far each scroll pass goes below the top: two screens of the 900 pt sidebar, or the whole list.
    nonisolated static let scrollDepth: CGFloat? = wholeBench ? nil : 1_800

    static func measure(_ count: Int, pointer: Bool = false, ticks: Int = 0, moveToTopEvery: Int = 0) -> [SidebarScrollBench.Frame] {
        let bench = SidebarScrollBench(count: count, pointerOverList: pointer)
        defer { bench.close() }
        bench.ticksPerFrame = ticks
        bench.moveToTopEvery = moveToTopEvery
        let frames = bench.run(depth: scrollDepth)
        print(SidebarScrollBench.summary(count, frames) + " | pointer=\(pointer) ticks=\(ticks) moveToTopEvery=\(moveToTopEvery)")
        return frames
    }

    /// The default scroll at 500 workspaces stays a few hundred frames, so the budget test holds the
    /// main thread for seconds, not minutes. Over the whole list each pass was about 1,200 frames, the
    /// budget test scrolled four such lists three passes each, and on a loaded CI Mac (about 50 ms a
    /// frame) it held the main actor past the swift-test stall watchdog (300 s with no test finished)
    /// with every other main-actor test queued behind it: five full runs in a row on 2026-10-29
    /// (391 to 439 tests open when the watchdog killed the run).
    @Test func aDefaultScrollAtFiveHundredWorkspacesStaysAFewHundredFrames() {
        let frames = Self.measure(500)
        #expect(frames.count <= 400, "a default scroll at 500 workspaces took \(frames.count) frames")
    }

    /// A scroll keeps few row views in the list: the visible rows, a short overscan and a pool of
    /// parked views for the next rows, not tenfold the visible rows (each view's subtree costs
    /// every frame).
    @Test func aScrolledListHoldsAFewScreensOfRowViews() {
        let bench = SidebarScrollBench(count: 500)
        defer { bench.close() }
        _ = bench.run(passes: 1, depth: Self.scrollDepth)
        let held = bench.rowViewsInList, visible = bench.visibleRows
        print("SIDEBAR-SCROLL-VIEWS n=500 visible=\(visible) held=\(held)")
        #expect(held <= visible * 2, "the list holds \(held) row views for \(visible) visible rows")
    }

    /// A slow runner, stood in deterministically: every frame and every reference sample does the
    /// reference work `slowdown` times, so the runner is that much slower at both. This host's own
    /// unslowed reference is the nominal one and its unslowed frames set the budget, so the host's
    /// speed cancels out. The slowed frames break that budget as it is, and hold it once the
    /// calibration scales it by the slowed reference.
    @Test func aSlowRunnerScalesTheBudgetByItsReferenceWorkload() {
        let slowdown = 3
        func work(_ times: Int) { for _ in 0..<times { FrameBudgetCalibration.referenceWork() } }
        func frames(_ times: Int) -> [Double] { (0..<60).map { _ in FrameBudgetCalibration.cpuMs { work(times) } } }
        work(4) // warm up
        let nominalMs = SidebarScrollBench.percentile(frames(1), 0.5)
        let fast = frames(1)
        var slow = FrameBudgetCalibration(nominalMs: nominalMs, reference: { work(slowdown) })
        slow.checkpoint()
        let slowed = frames(slowdown)
        slow.checkpoint()
        let budget = 1.5 * SidebarScrollBench.percentile(fast, 0.95)
        let slowedP95 = SidebarScrollBench.percentile(slowed, 0.95)
        print(String(format: "FRAME-BUDGET-CALIBRATION-TEST reference %.3f ms, budget %.3f ms, slowed p95 %.3f ms | ",
                     nominalMs, budget, slowedP95) + slow.summary)
        #expect(slowedP95 > budget, "the stand-in runner is not slow enough to break an unscaled budget")
        if let reason = slow.skipReason { return print("FRAME-BUDGET-CALIBRATION-TEST skipped: \(reason)") }
        #expect(slowedP95 < slow.budget(budget),
                "a runner \(slowdown)x slower at the reference took \(slowedP95) ms a frame against a budget scaled to \(slow.budget(budget)) ms")
    }

    /// A runner faster than nominal keeps the budget as it is, and one far slower than the cap skips
    /// the budget with a reason instead of scaling it without bound.
    @Test func aFastRunnerKeepsTheBudgetAndATooSlowOneSkipsIt() {
        var fast = FrameBudgetCalibration(nominalMs: 1_000)
        fast.checkpoint()
        #expect(fast.factor == 1 && fast.budget(8) == 8, "\(fast.summary)")
        var tooSlow = FrameBudgetCalibration(nominalMs: 0.001)
        tooSlow.checkpoint()
        #expect(tooSlow.skipReason?.contains("slower than nominal") == true, "\(tooSlow.summary)")
    }

    /// The 8 ms budget is for the hosts it was set on; a slower runner gets it scaled by its own
    /// reference workload, timed before the scrolls and after each (FrameBudgetCalibration), or skips
    /// the timed checks with the reason printed.
    @Test(.disabled("Quarantined: the CPU-only calibration misses CI runners' slow commits, so the 8 ms p95 fails unscaled, https://github.com/manaflow-ai/cmux/issues/30973"))
    func scrollingFiveHundredWorkspacesStaysInsideTheFrameBudget() {
        var calibration = FrameBudgetCalibration()
        calibration.checkpoint()
        for count in [10, 100] { _ = Self.measure(count) }
        var timed: [(what: String, p95: Double)] = []
        for pointer in [false, true] {
            let frames = Self.measure(500, pointer: pointer)
            calibration.checkpoint()
            timed.append(("p95 scroll frame at 500 workspaces (pointer over the list: \(pointer))",
                          SidebarScrollBench.percentile(frames.map(\.cpuMs), 0.95)))
            #expect(frames.map(\.reloads).reduce(0, +) == 0, "a scroll laid the list out again (pointer: \(pointer))")
        }
        // Agents streaming while the list scrolls: three status ticks a frame.
        let ticking = Self.measure(500, pointer: true, ticks: 3)
        calibration.checkpoint()
        timed.append(("p95 scroll frame at 500 workspaces with ticking agents", SidebarScrollBench.percentile(ticking.map(\.cpuMs), 0.95)))
        // Not a check: a notification moving a workspace to the top every half second.
        _ = Self.measure(500, pointer: true, ticks: 3, moveToTopEvery: 60)
        print(calibration.summary)
        if let reason = calibration.skipReason { return print("SIDEBAR-SCROLL-BUDGET skipped the 8 ms checks: \(reason)") }
        let budget = calibration.budget(8)
        for (what, p95) in timed {
            #expect(p95 < budget, "\(what) took \(p95) ms of main thread, over 8 ms scaled by \(calibration.factor) to \(budget) ms")
        }
    }
}

/// Not a check: where a sidebar scroll frame spends its main-thread time (its own suite, so the
/// sampler has a suite timeout of its own). Opt-in with `CMUX_SAMPLE_PROFILE=1` (`SelfSampler`).
@MainActor @Suite(.serialized, .enabled(if: SelfSampler.enabled, "self-sampling profile; set CMUX_SAMPLE_PROFILE=1"))
struct SidebarScrollProfile {
    /// Not a check: where a scroll frame spends its main-thread time.
    @Test func profileOfASidebarScroll() async throws {
        let bench = SidebarScrollBench(count: 500, pointerOverList: true)
        defer { bench.close() }
        bench.ticksPerFrame = 3
        _ = bench.run(passes: 1)
        try await bench.profile(seconds: 5)
    }

    /// Not a check: where a scroll spends its time when notifications move workspaces to the top
    /// (`notifications.attention.moveToTop`, an opt-in) every few frames.
    @Test func profileOfASidebarScrollWithMovesToTop() async throws {
        let bench = SidebarScrollBench(count: 500, pointerOverList: true)
        defer { bench.close() }
        bench.moveToTopEvery = 4
        _ = bench.run(passes: 1)
        try await bench.profile(seconds: 5)
    }
}
