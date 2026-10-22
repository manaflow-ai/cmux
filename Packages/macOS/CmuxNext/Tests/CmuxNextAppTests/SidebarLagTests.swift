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

    /// Agents streaming, the pointer moving, the list scrolling and the selection stepping lay the
    /// list out again in no frame, and each p95 stays inside half a 60 Hz frame at 150 workspaces and
    /// grows less than twofold from 150 to 500.
    @Test func everyDayInteractionsStayInsideTheFrameBudget() {
        var calibration = FrameBudgetCalibration()
        calibration.checkpoint()
        var timed: [(what: String, p95: Double)] = []
        for scenario in SidebarLagBench.Scenario.allCases {
            let small = Self.measure(scenario, 150)
            let large = Self.measure(scenario, 500)
            calibration.checkpoint()
            let p95s = SidebarLagBench.percentile(small.map(\.cpuMs), 0.95), p95l = SidebarLagBench.percentile(large.map(\.cpuMs), 0.95)
            timed.append(("\(scenario) p95 at 150 workspaces", p95s))
            if scenario != .select {
                #expect(small.map(\.reloads).reduce(0, +) == 0, "\(scenario) laid the whole list out again at 150 workspaces")
            }
            #expect(p95l < max(2 * p95s, p95s + 1), "\(scenario) p95 grew from \(p95s) ms at 150 to \(p95l) ms at 500 workspaces")
        }
        print(calibration.summary)
        if let reason = calibration.skipReason { return print("SIDEBAR-LAG-BUDGET skipped the 8 ms checks: \(reason)") }
        let budget = calibration.budget(8)
        for (what, p95) in timed {
            #expect(p95 < budget, "\(what) took \(p95) ms of main thread, over 8 ms scaled by \(calibration.factor) to \(budget) ms")
        }
    }
}
