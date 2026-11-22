import AppKit
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-25: "large groups need to be virtualized better / be lazy better, people will have humongous
/// groups, and groups of groups." One group of 1,000 and 10,000 workspaces and a deep chain of nested groups:
/// open (build + first layout), scroll, fold/unfold and reorder. Each prints one `SIDEBAR-HUGE-BENCH` line; the
/// asserts are loose ceilings that fail an eager path (row views or layout cost that grow with the group).
///
/// The scroll before the fold goes `scrollDepth` (1,800 pt, two screens) down and back, so no test's frame count
/// grows with its group: over the whole list, 10,000 rows took about 15,000 frames a pass and held the main thread
/// past the swift-test stall watchdog (300 s with no test finished). The ceilings are on open, fold, unfold and
/// reorder, none on the scroll. `CMUX_SIDEBAR_HUGE_BENCH=1`, like the other `*_BENCH` flags, scrolls the whole
/// list and runs the 10k benches that check nothing.
@MainActor @Suite(.serialized)
struct SidebarHugeGroupTests {
    nonisolated static let wholeBench = ProcessInfo.processInfo.environment["CMUX_SIDEBAR_HUGE_BENCH"] == "1"
    /// How far each scroll pass goes below the top: two screens of the 900 pt sidebar, or the whole list.
    nonisolated static let scrollDepth: CGFloat? = wholeBench ? nil : 1_800

    static func ms(_ body: () -> Void) -> Double {
        let t0 = SidebarScrollBench.threadCPU()
        body()
        return (SidebarScrollBench.threadCPU() - t0) * 1_000
    }

    struct Numbers {
        var openMs = 0.0, scrollP50 = 0.0, scrollP95 = 0.0, foldMs = 0.0, unfoldMs = 0.0, reorderMs = 0.0, rowViews = 0
    }

    static func measure(_ label: String, count: Int, shape: SidebarScrollBench.Shape, groupID: String? = "sb-g0") -> Numbers {
        var n = Numbers()
        var bench: SidebarScrollBench?
        n.openMs = ms { bench = SidebarScrollBench(count: count, shape: shape) }
        guard let bench else { return n }
        defer { bench.close() }
        let frames = bench.run(passes: 1, depth: scrollDepth)
        let cpu = frames.map(\.cpuMs)
        n.scrollP50 = SidebarScrollBench.percentile(cpu, 0.5)
        n.scrollP95 = SidebarScrollBench.percentile(cpu, 0.95)
        n.rowViews = bench.rowViewsInList
        if let groupID {
            let id = GroupID(groupID)
            n.foldMs = ms { _ = bench.model.setGroupCollapsed(id, true); bench.drain(); bench.drawFrame() }
            n.unfoldMs = ms { _ = bench.model.setGroupCollapsed(id, false); bench.drain(); bench.drawFrame() }
        }
        // Reorder: the last loose-or-grouped workspace of the first group moves to its top, as a structural set.
        n.reorderMs = ms {
            var sections = bench.model.sections
            if case var .group(group)? = sections.first?.nodes.first, group.workspaces.count > 1 {
                group.workspaces.insert(group.workspaces.removeLast(), at: 0)
                sections[0].nodes[0] = .group(group)
                bench.model.sections = sections
                bench.sidebar.renderNow()
            }
            bench.drain(); bench.drawFrame()
        }
        print(String(format: "SIDEBAR-HUGE-BENCH %@ n=%d | open %.1f ms | scroll p50 %.2f p95 %.2f ms over %d frames | fold %.1f unfold %.1f reorder %.1f ms | rowViews %d",
                     label, count, n.openMs, n.scrollP50, n.scrollP95, frames.count, n.foldMs, n.unfoldMs, n.reorderMs, n.rowViews))
        return n
    }

    @Test func oneGroup1k() { _ = Self.measure("one-group", count: 1_000, shape: .oneGroup) }
    /// 10,000 in one group on an M4 Pro (aws-m4pro-3). Before: open 647, fold 94, unfold 222, reorder 334 ms (a
    /// `DateComponentsFormatter` per row's age; a fold copied and sorted every member row). After: open 452, fold 58,
    /// unfold 129, reorder 235. The ceilings sit between the two, so they fail on the old code; the rest of the cost
    /// is row content made for every row of a layout (the next step: build only the rows in view).
    @Test(.disabled("Quarantined: absolute ms ceilings, not scaled to the runner, fail on every CI runner class, https://github.com/manaflow-ai/cmux/issues/30971"))
    func oneGroup10k() {
        let n = Self.measure("one-group", count: 10_000, shape: .oneGroup)
        #expect(n.openMs < 540, "open \(n.openMs) ms")
        #expect(n.unfoldMs < 175, "unfold \(n.unfoldMs) ms")
        #expect(n.foldMs < 80, "fold \(n.foldMs) ms")
        #expect(n.reorderMs < 290, "reorder \(n.reorderMs) ms")
    }
    @Test func nested1k() { _ = Self.measure("nested-20", count: 1_000, shape: .nested(depth: 20), groupID: "sb-g1") }
    /// Not checks: 10k benches with no ceiling. Opt-in with `CMUX_SIDEBAR_HUGE_BENCH=1`.
    @Test(.enabled(if: SidebarHugeGroupTests.wholeBench, "10k bench that checks nothing; set CMUX_SIDEBAR_HUGE_BENCH=1"))
    func nested10k() { _ = Self.measure("nested-20", count: 10_000, shape: .nested(depth: 20), groupID: "sb-g1") }
    @Test(.enabled(if: SidebarHugeGroupTests.wholeBench, "10k bench that checks nothing; set CMUX_SIDEBAR_HUGE_BENCH=1"))
    func manyCollapsed10k() { _ = Self.measure("many-collapsed", count: 10_000, shape: .manyCollapsed(perGroup: 10), groupID: "sb-g1") }

    /// Not a check: samples fold/unfold/reorder cycles on 10k in one group (`SSB` lines: the
    /// heaviest main-thread stacks). Opt-in with `CMUX_SAMPLE_PROFILE=1` (`SelfSampler`).
    @Test(.enabled(if: SelfSampler.enabled, "self-sampling profile; set CMUX_SAMPLE_PROFILE=1"))
    func profile10k() async throws {
        let bench = SidebarScrollBench(count: 10_000, shape: .oneGroup)
        defer { bench.close() }
        let (report, _) = try await SelfSampler.run(name: "huge", seconds: 8) { _ in
            try await Task.sleep(for: .milliseconds(500)) // bounded: lets sample attach
            let end = Date().addingTimeInterval(8)
            let id = GroupID("sb-g0")
            while Date() < end {
                _ = bench.model.setGroupCollapsed(id, true); bench.drain(); bench.drawFrame()
                _ = bench.model.setGroupCollapsed(id, false); bench.drain(); bench.drawFrame()
                var sections = bench.model.sections
                if case var .group(group)? = sections.first?.nodes.first {
                    group.workspaces.insert(group.workspaces.removeLast(), at: 0)
                    sections[0].nodes[0] = .group(group)
                    bench.model.sections = sections
                    bench.sidebar.renderNow()
                }
                bench.drain(); bench.drawFrame()
                await Task.yield()
            }
        }
        let text = report ?? ""
        var inMain = false, printed = 0
        for line in text.components(separatedBy: "\n") {
            if line.contains("Thread_") { inMain = line.contains("main-thread") || line.contains("DispatchQueue_1:") }
            guard inMain, printed < 400 else { continue }
            let trimmed = line.drop { $0 == " " || $0 == "+" || $0 == "!" || $0 == ":" || $0 == "|" }
            guard let n = Int(trimmed.prefix { $0.isNumber }), n >= 40 else { continue }
            print("SSB " + String(line.prefix(220)))
            printed += 1
        }
        if let top = text.components(separatedBy: "\n").firstIndex(where: { $0.hasPrefix("Sort by top of stack") }) {
            for line in text.components(separatedBy: "\n")[top..<min(top + 40, text.components(separatedBy: "\n").count)] { print("SSB-TOP " + line) }
        }
    }
}
