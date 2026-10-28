import AppKit
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-21: "i feel like sidebar got a lot laggier recently." Scrolling, hovering, agents
/// ticking and clicking through the list each cost a frame of main thread that does not grow with the
/// number of workspaces: no per-tick or per-hover layout of the whole list and no work for rows off
/// screen. Prints one `SIDEBAR-LAG-BENCH` line per scenario and size (sidebar-lag-DESIGN.md).
@MainActor @Suite(.serialized)
struct SidebarLagTests {
    static func measure(_ scenario: SidebarLagBench.Scenario, _ count: Int) -> [SidebarLagBench.Frame] {
        let bench = SidebarLagBench(count: count)
        defer { bench.close() }
        let frames = bench.run(scenario)
        print(SidebarLagBench.summary(scenario, count, frames))
        return frames
    }

    /// A pull request read landing (one row's badge turns red) patches that row; it does not lay out
    /// every row of the list again.
    @Test func aBadgeChangePatchesItsRowOnly() {
        let bench = SidebarLagBench(count: 500)
        defer { bench.close() }
        bench.drain()
        _ = SidebarPerfCounters.report(reset: true)
        SidebarSessionTree.shared.pullRequests[bench.ids[2]] = SidebarPullRequestBadge(count: 2, status: .failing)
        bench.sidebar.renderNow() // the render the observation runs, in this turn (`SidebarSameTurn`)
        bench.drain()
        bench.drawFrame()
        let counts = SidebarPerfCounters.report(reset: true)
        #expect((counts["list_reloads"] ?? 0) == 0, "a badge change laid the list out again: \(counts)")
        #expect((counts["row_patches"] ?? 0) >= 1, "the badge change patched no row: \(counts)")
    }

    /// Agents streaming, the pointer moving, the list scrolling and the selection stepping lay the
    /// list out again in no frame, and each p95 stays inside half a 60 Hz frame at 150 workspaces and
    /// grows less than twofold from 150 to 500.
    ///
    /// Each size is timed twice, interleaved (150, 500, 150, 500), and the lower p95 counts: a real
    /// regression slows both passes, a runner's noisy stretch slows one. The growth check's 1 ms
    /// floor is CPU time like the 8 ms budget, so it scales with the runner the same way. One pass
    /// each with an unscaled floor failed a576's green run (2.56 ms at 150, 4.27 ms at 500) where
    /// three runs at the same code on aws-m4pro-1 measured at most 1.63 ms at 500 (2026-10-23).
    @Test func everyDayInteractionsStayInsideTheFrameBudget() {
        var calibration = FrameBudgetCalibration()
        calibration.checkpoint()
        var timed: [(what: String, p95: Double)] = []
        var growth: [(scenario: SidebarLagBench.Scenario, small: Double, large: Double)] = []
        for scenario in SidebarLagBench.Scenario.allCases {
            var p95s = Double.infinity, p95l = Double.infinity
            for _ in 0..<2 {
                let small = Self.measure(scenario, 150)
                let large = Self.measure(scenario, 500)
                p95s = min(p95s, SidebarLagBench.percentile(small.map(\.cpuMs), 0.95))
                p95l = min(p95l, SidebarLagBench.percentile(large.map(\.cpuMs), 0.95))
                if scenario != .select {
                    #expect(small.map(\.reloads).reduce(0, +) == 0, "\(scenario) laid the whole list out again at 150 workspaces")
                }
            }
            calibration.checkpoint()
            timed.append(("\(scenario) p95 at 150 workspaces", p95s))
            growth.append((scenario, p95s, p95l))
        }
        print(calibration.summary)
        for (scenario, p95s, p95l) in growth {
            #expect(p95l < max(2 * p95s, p95s + calibration.budget(1)),
                    "\(scenario) p95 grew from \(p95s) ms at 150 to \(p95l) ms at 500 workspaces (runner factor \(calibration.factor))")
        }
        if let reason = calibration.skipReason { return print("SIDEBAR-LAG-BUDGET skipped the 8 ms checks: \(reason)") }
        let budget = calibration.budget(8)
        for (what, p95) in timed {
            #expect(p95 < budget, "\(what) took \(p95) ms of main thread, over 8 ms scaled by \(calibration.factor) to \(budget) ms")
        }
    }
}
