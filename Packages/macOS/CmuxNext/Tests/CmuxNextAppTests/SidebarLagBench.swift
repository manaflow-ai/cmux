import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Darwin
import Foundation
import QuartzCore

/// Lawrence 2026-10-21: "i feel like sidebar got a lot laggier recently." One sidebar over `count`
/// workspaces shaped like a long-running window (a third in groups of eight, agent rows with a status
/// line, unread counts, spinners, presence, branches), driven the four ways a user meets it: a
/// trackpad scroll with agents streaming, the pointer sweeping the rows, agents ticking under a still
/// pointer, and clicks walking the selection down the list. Each step is one display frame (the
/// change, then layout, display and commit), and its main-thread CPU is the frame's cost
/// (sidebar-lag-DESIGN.md). Self-contained so the same file times older commits.
@MainActor
final class SidebarLagBench {
    enum Scenario: String, CaseIterable { case scroll, hover, ticks, select }

    struct Frame {
        var cpuMs: Double
        /// Full list layouts in the frame (`list_reloads`).
        var reloads: Int
        /// Row views configured in the frame.
        var configures: Int
    }

    let sidebar: SidebarView
    let model: SidebarModel
    let window: NSWindow
    let count: Int
    private(set) var rows: [SidebarWorkspace] = []
    let ids: [WorkspaceID]
    private var tick = 0
    var list: SidebarListView { sidebar.list }
    var clip: NSClipView { sidebar.scrollView.contentView }

    init(count: Int, height: CGFloat = 900) {
        _ = NSApplication.shared
        self.count = count
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ids = (0..<count).map { WorkspaceID("lag-\($0)") }
        self.ids = ids
        let now = Date()
        func ws(_ index: Int) -> SidebarWorkspace {
            var w = SidebarWorkspace(
                id: ids[index], title: "a\(index) · Agent workspace \(index) with a longer title",
                directory: "~/fun/cmux-worktrees/feature-\(index)", branch: "feat-\(index)",
                status: index % 2 == 0 ? "Running fleet tests on cmux1\(index % 10)s, step \(index)" : nil,
                lastActivity: now.addingTimeInterval(-Double(index * 37)),
                kind: index % 3 == 0 ? .terminal : .harness,
                unread: index % 5 == 0 ? .count(index % 9 + 1) : index % 7 == 0 ? .dot : .none,
                activity: index % 6 == 0 ? .working(progress: nil) : index % 11 == 0 ? .waiting(kind: nil) : .idle,
                agentBrand: index % 3 == 0 ? nil : "claude", agentName: "Claude Code")
            if index % 4 == 0 { w.presence = [SidebarPresence(id: "p\(index)", name: "Claude Code", activity: .editing)] }
            if index % 13 == 0 { w.muted = true }
            SidebarLagFeatures.decorate(&w, index)
            return w
        }
        let grouped = count / 3, perGroup = 8
        var nodes: [SidebarNode] = []
        var next = 0, g = 0
        while next < grouped {
            let members = (next..<min(grouped, next + perGroup)).map(ws)
            nodes.append(.group(SidebarGroup(id: GroupID("lag-g\(g)"), name: "Group \(g)", color: .green, workspaces: members)))
            next += members.count
            g += 1
        }
        nodes += (next..<count).map { .workspace(ws($0)) }
        rows = (0..<count).map(ws)
        model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: ids.first)
        sidebar = SidebarView(model: model, design: DesignSettings())
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        window.orderFrontRegardless()
        SidebarLagFeatures.attach(model, ids)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        drawFrame()
    }

    func close() {
        SidebarLagFeatures.detach()
        window.close()
    }

    func drawFrame() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func drain() { for _ in 0..<4 { RunLoop.main.run(mode: .default, before: Date()) } }

    var maxY: CGFloat { max(0, list.frame.height - clip.bounds.height) }

    /// The pointer over the list at `y` in the list's visible area (0 its top), as a window point.
    private func pointer(atVisibleY y: CGFloat) -> NSPoint {
        let visible = clip.bounds
        let inList = NSPoint(x: 130, y: list.isFlipped ? visible.minY + y : visible.maxY - y)
        return list.convert(inList, to: nil)
    }

    private func move(to windowPoint: NSPoint) {
        let screen = window.convertPoint(toScreen: windowPoint)
        list.hoverCards.pointerLocation = { screen }
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 0, pressure: 0) else { return }
        list.mouseMoved(with: event)
    }

    /// `ticks` agents change their status line (and, where the build has it, their step) this frame.
    private func applyTicks(_ ticks: Int) {
        guard ticks > 0 else { return }
        tick += 1
        var patched: [SidebarWorkspace] = []
        for k in 0..<ticks {
            let index = (tick * 7 + k * 31) % rows.count
            rows[index].status = "Streaming reply, \(tick) tokens"
            rows[index].lastActivity = Date()
            SidebarLagFeatures.tick(&rows[index], tick)
            patched.append(rows[index])
        }
        if !model.patchWorkspaces(patched) { model.setSections(model.sections) }
    }

    private func timed(_ body: () -> Void) -> Frame {
        _ = SidebarPerfCounters.report(reset: true)
        let cpu0 = Self.threadCPU()
        body()
        drawFrame()
        let cpu1 = Self.threadCPU()
        let counts = SidebarPerfCounters.report(reset: true)
        return Frame(cpuMs: (cpu1 - cpu0) * 1_000, reloads: counts["list_reloads"] ?? 0, configures: counts["row_configures"] ?? 0)
    }

    /// Runs `scenario` and returns its frames (a warm-up pass dropped).
    func run(_ scenario: Scenario) -> [Frame] {
        clip.scroll(to: .zero)
        sidebar.scrollView.reflectScrolledClipView(clip)
        move(to: pointer(atVisibleY: 450))
        drain()
        drawFrame()
        var frames: [Frame] = []
        for pass in 0..<3 {
            var out: [Frame] = []
            switch scenario {
            case .scroll:
                // A fast trackpad scroll (40 pt a frame) with the pointer resting over the list and three agents streaming.
                var y: CGFloat = 0
                func step(_ to: CGFloat) {
                    out.append(timed {
                        applyTicks(3); drain()
                        clip.scroll(to: NSPoint(x: 0, y: to)); sidebar.scrollView.reflectScrolledClipView(clip)
                        list.updateHover()
                    })
                }
                while y < maxY { y = min(maxY, y + 40); step(y) }
                while y > 0 { y = max(0, y - 40); step(y) }
            case .hover:
                // The pointer sweeps down the visible rows and back, 12 pt a frame, one agent streaming.
                var y: CGFloat = 20
                while y < 880 { y += 12; let p = pointer(atVisibleY: y); out.append(timed { applyTicks(1); drain(); move(to: p) }) }
                while y > 20 { y -= 12; let p = pointer(atVisibleY: y); out.append(timed { applyTicks(1); drain(); move(to: p) }) }
            case .ticks:
                // The pointer still over the list while three agents stream each frame.
                for _ in 0..<180 { out.append(timed { applyTicks(3); drain() }) }
            case .select:
                // Clicks walk the selection down the first 40 workspaces (each click renders in its own turn).
                for k in 0..<min(40, ids.count) {
                    let id = ids[(k + 1) % ids.count]
                    out.append(timed { model.activeWorkspaceID = id; sidebar.renderNow(); drain() })
                }
            }
            if pass > 0 { frames += out }
            drain()
        }
        return frames
    }

    static func threadCPU() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// Writes each frame's main-thread CPU and configured rows as result-v1 when CMUX_PERF_RESULT_DIR is set
    /// (lab story swift-sidebar-lag).
    static func record(_ scenario: Scenario, _ count: Int, _ frames: [Frame]) throws {
        guard let results = try PerfResultWriter() else { return }
        let name = "swift.sidebar_lag.\(scenario.rawValue).\(count)"
        try results.record("\(name).cpu", unit: .ms, samples: frames.map(\.cpuMs))
        try results.record("\(name).configures", unit: .count, samples: frames.map(\.configures))
    }

    static func summary(_ scenario: Scenario, _ count: Int, _ frames: [Frame]) -> String {
        let cpu = frames.map(\.cpuMs)
        return String(format: "SIDEBAR-LAG-BENCH %@ n=%d frames=%d | cpu_ms p50 %.2f p95 %.2f p99 %.2f max %.2f | over8ms %d over16ms %d | reloads %d configures/frame %.2f",
                      scenario.rawValue, count, frames.count, percentile(cpu, 0.5), percentile(cpu, 0.95), percentile(cpu, 0.99),
                      cpu.max() ?? 0, cpu.filter { $0 > 8 }.count, cpu.filter { $0 > 16 }.count,
                      frames.map(\.reloads).reduce(0, +),
                      Double(frames.map(\.configures).reduce(0, +)) / Double(max(frames.count, 1)))
    }
}
