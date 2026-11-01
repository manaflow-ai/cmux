import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Darwin
import Foundation
import QuartzCore
import Testing

/// Lawrence 2026-10-21: "i feel like sidebar got a lot laggier recently." Scrolling, hovering, agents
/// ticking and clicking through the list each cost a frame of main thread that does not grow with the
/// number of workspaces: no per-tick or per-hover layout of the whole list and no work for rows off
/// screen. Prints one `SIDEBAR-LAG-BENCH` line per scenario and size (sidebar-lag-DESIGN.md).
@MainActor @Suite(.serialized)
struct SidebarLagTests {
    static var diag: [String] = []
    static func measure(_ scenario: SidebarLagBench.Scenario, _ count: Int) -> [SidebarLagBench.Frame] {
        let t0 = CACurrentMediaTime(), c0 = SidebarLagBench.threadCPU()
        let bench = SidebarLagBench(count: count)
        let t1 = CACurrentMediaTime(), c1 = SidebarLagBench.threadCPU()
        defer { bench.close() }
        let frames = bench.run(scenario)
        diag.append(String(format: "SIDEBAR-LAG-DIAG %@ n=%d init wall %.0fms cpu %.0fms run wall %.0fms cpu %.0fms frames %d", scenario.rawValue, count, (t1 - t0) * 1000, (c1 - c0) * 1000, (CACurrentMediaTime() - t1) * 1000, (SidebarLagBench.threadCPU() - c1) * 1000, frames.count))
        print(SidebarLagBench.summary(scenario, count, frames))
        return frames
    }

    /// A pull request read landing (one row's badge turns red) patches that row; it does not lay out
    /// every row of the list again. Measured in a child process too: in the full run its two frames
    /// in the shared process took 281 s.
    @Test func aBadgeChangePatchesItsRowOnly() async throws {
        let url = Self.reportURL("badge", parent: getpid())
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(processExitsWith: .success) { await SidebarLagTests.badgeChangeInChild() }
        let data = try #require(try? Data(contentsOf: url), "the child left no badge-change report")
        let r = try JSONDecoder().decode(BadgeReport.self, from: data)
        try #require(r.parent == getpid(), "the report is another process's (parent \(r.parent))")
        #expect(r.listReloads == 0, "a badge change laid the list out again: \(r.counts)")
        #expect(r.rowPatches >= 1, "the badge change patched no row: \(r.counts)")
    }

    nonisolated struct BadgeReport: Codable, Sendable {
        var parent: pid_t
        var listReloads = 0, rowPatches = 0
        var counts: [String: Int] = [:]
    }

    /// The child: one badge change on a 500-row sidebar, its counters written next to the parent's pid.
    static func badgeChangeInChild() {
        var report = BadgeReport(parent: getppid())
        let bench = SidebarLagBench(count: 500)
        bench.drain()
        _ = SidebarPerfCounters.report(reset: true)
        SidebarSessionTree.shared.pullRequests[bench.ids[2]] = SidebarPullRequestBadge(count: 2, status: .failing)
        bench.sidebar.renderNow() // the render the observation runs, in this turn (`SidebarSameTurn`)
        bench.drain()
        bench.drawFrame()
        let counts = SidebarPerfCounters.report(reset: true)
        bench.close()
        report.listReloads = counts["list_reloads"] ?? 0
        report.rowPatches = counts["row_patches"] ?? 0
        report.counts = counts
        write(report, to: reportURL("badge", parent: report.parent))
    }

    /// Writes a child's report in one atomic replace; a report it cannot write ends the child with a
    /// failure. The child is a fresh process (Swift Testing spawns the test binary for an exit test; it
    /// does not fork), so it holds none of the parent's windows, and the parent awaits its exit, so no
    /// child outlives the test that started it.
    static func write(_ report: some Encodable, to url: URL) {
        do {
            try JSONEncoder().encode(report).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("sidebar-lag: the report was not written: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
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
    ///
    /// The frames are timed in a child process (an exit test), where this test's window is the only
    /// one. Each frame's commit walks every window in its process, and in the full `swift test` run
    /// other suites leave theirs open: there its hundreds of frames held the main thread for over 19
    /// minutes, until the stall watchdog (300 s with no test finished) killed the run. Alone it takes
    /// 13 to 19 s with the same frame numbers. The child writes what it measured for this test to
    /// check against the same budgets as before.
    @Test func everyDayInteractionsStayInsideTheFrameBudget() async throws {
        let url = Self.reportURL("frames", parent: getpid())
        // Only this run's child writes the report: an older one never stands in for it.
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        defer { try? FileManager.default.removeItem(at: url) }
        let x0 = CACurrentMediaTime()
        await #expect(processExitsWith: .success) { await SidebarLagTests.measureInChild() }
        print(String(format: "SIDEBAR-LAG-DIAG child %.0fms", (CACurrentMediaTime() - x0) * 1000))
        let data = try #require(try? Data(contentsOf: url), "the child left no sidebar-lag report")
        let r = try JSONDecoder().decode(Report.self, from: data)
        try #require(r.parent == getpid(), "the report is another process's (parent \(r.parent))")
        for line in r.lines { print(line) }
        try #require(r.scenarios.count == SidebarLagBench.Scenario.allCases.count, "the child measured \(r.scenarios.map(\.scenario))")

        for s in r.scenarios where s.scenario != SidebarLagBench.Scenario.select.rawValue {
            for reloads in s.reloadsAt150 {
                #expect(reloads == 0, "\(s.scenario) laid the whole list out again at 150 workspaces")
            }
        }
        for s in r.scenarios {
            #expect(s.p95At500 < max(2 * s.p95At150, s.p95At150 + r.budget1),
                    "\(s.scenario) p95 grew from \(s.p95At150) ms at 150 to \(s.p95At500) ms at 500 workspaces (runner factor \(r.factor))")
        }
        if let reason = r.skipReason { return print("SIDEBAR-LAG-BUDGET skipped the 8 ms checks: \(reason)") }
        for s in r.scenarios {
            #expect(s.p95At150 < r.budget8,
                    "\(s.scenario) p95 at 150 workspaces took \(s.p95At150) ms of main thread, over 8 ms scaled by \(r.factor) to \(r.budget8) ms")
        }
    }

    /// One scenario's timings, as the child measured them.
    nonisolated struct ScenarioReport: Codable, Sendable {
        var scenario: String
        /// The lower of the two passes' p95, ms.
        var p95At150: Double, p95At500: Double
        /// Full list layouts in each 150-workspace pass.
        var reloadsAt150: [Int]
    }

    /// What the child measured, and its runner calibration.
    nonisolated struct Report: Codable, Sendable {
        /// The test process that started the child.
        var parent: pid_t
        var scenarios: [ScenarioReport] = []
        var factor = 1.0, budget1 = 0.0, budget8 = 0.0
        var skipReason: String?
        /// The `SIDEBAR-LAG-BENCH` and calibration lines, for the parent to print.
        var lines: [String] = []
    }

    /// Where the child for `test` leaves its report.
    nonisolated static func reportURL(_ test: String, parent: pid_t) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cmux-sidebar-lag-\(test)-\(parent).json")
    }

    /// The child: times every scenario at both sizes and writes the report next to its parent's pid
    /// (a report it cannot write ends the child with a failure).
    static func measureInChild() {
        var report = Report(parent: getppid())
        var calibration = FrameBudgetCalibration()
        calibration.checkpoint()
        for scenario in SidebarLagBench.Scenario.allCases {
            var p95s = Double.infinity, p95l = Double.infinity
            var reloads: [Int] = []
            for _ in 0..<2 {
                let small = Self.measure(scenario, 150)
                let large = Self.measure(scenario, 500)
                report.lines += [SidebarLagBench.summary(scenario, 150, small), SidebarLagBench.summary(scenario, 500, large)]
                p95s = min(p95s, SidebarLagBench.percentile(small.map(\.cpuMs), 0.95))
                p95l = min(p95l, SidebarLagBench.percentile(large.map(\.cpuMs), 0.95))
                reloads.append(small.map(\.reloads).reduce(0, +))
            }
            calibration.checkpoint()
            report.scenarios.append(ScenarioReport(scenario: scenario.rawValue, p95At150: p95s, p95At500: p95l, reloadsAt150: reloads))
        }
        report.lines += diag
        report.lines.append(calibration.summary)
        report.factor = calibration.factor
        report.budget1 = calibration.budget(1)
        report.budget8 = calibration.budget(8)
        report.skipReason = calibration.skipReason
        write(report, to: reportURL("frames", parent: report.parent))
    }
}
