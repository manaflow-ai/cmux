import AppKit
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-25: "large groups need to be virtualized better / be lazy better, people will have humongous
/// groups, and groups of groups." One group of 1,000 and 10,000 workspaces and a deep chain of nested groups:
/// open (build + first layout), scroll, fold/unfold and reorder. Each prints one `SIDEBAR-HUGE-BENCH` line; the
/// asserts are loose ceilings that fail an eager path (row views or layout cost that grow with the group).
@MainActor @Suite(.serialized)
struct SidebarHugeGroupTests {
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
        let frames = bench.run(passes: 1)
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
        print(String(format: "SIDEBAR-HUGE-BENCH %@ n=%d | open %.1f ms | scroll p50 %.2f p95 %.2f ms | fold %.1f unfold %.1f reorder %.1f ms | rowViews %d",
                     label, count, n.openMs, n.scrollP50, n.scrollP95, n.foldMs, n.unfoldMs, n.reorderMs, n.rowViews))
        return n
    }

    @Test func oneGroup1k() { _ = Self.measure("one-group", count: 1_000, shape: .oneGroup) }
    /// 10,000 in one group on an M4 Pro (aws-m4pro-3). Before: open 647, fold 94, unfold 222, reorder 334 ms (a
    /// `DateComponentsFormatter` per row's age; a fold copied and sorted every member row). After: open 452, fold 58,
    /// unfold 129, reorder 235. The ceilings sit between the two, so they fail on the old code; the rest of the cost
    /// is row content made for every row of a layout (the next step: build only the rows in view).
    @Test func oneGroup10k() {
        let n = Self.measure("one-group", count: 10_000, shape: .oneGroup)
        #expect(n.openMs < 540, "open \(n.openMs) ms")
        #expect(n.unfoldMs < 175, "unfold \(n.unfoldMs) ms")
        #expect(n.foldMs < 80, "fold \(n.foldMs) ms")
        #expect(n.reorderMs < 290, "reorder \(n.reorderMs) ms")
    }
    @Test func nested1k() { _ = Self.measure("nested-20", count: 1_000, shape: .nested(depth: 20), groupID: "sb-g1") }
    @Test func nested10k() { _ = Self.measure("nested-20", count: 10_000, shape: .nested(depth: 20), groupID: "sb-g1") }
    @Test func manyCollapsed10k() { _ = Self.measure("many-collapsed", count: 10_000, shape: .manyCollapsed(perGroup: 10), groupID: "sb-g1") }

    /// Samples fold/unfold/reorder cycles on 10k in one group (`SSB` lines: the heaviest main-thread stacks).
    @Test func profile10k() async throws {
        let bench = SidebarScrollBench(count: 10_000, shape: .oneGroup)
        defer { bench.close() }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("huge-\(getpid()).sample.txt")
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(getpid()), "8", "1", "-mayDie", "-file", output.path]
        try sampler.run()
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
        sampler.waitUntilExit()
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
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
