import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Darwin
import Foundation
import QuartzCore

/// Lawrence 2026-10-20: "I was just scrolling the sidebar and I encountered a ton of lag." A
/// sidebar over `count` workspaces shaped like a long-running window (a third in groups of eight,
/// agent rows with a status line, unread counts, working spinners, presence dots, branches and
/// ages), scrolled top to bottom and back in steps the size of a fast trackpad frame. Each step is
/// one display frame: the clip moves, then the window lays out, draws and commits, and the step's
/// main-thread CPU is that frame's cost (sidebar-scroll-perf-DESIGN.md).
@MainActor
final class SidebarScrollBench {
    struct Frame {
        /// Main-thread CPU of the frame (scroll, realization, layout, display, commit), ms.
        var cpuMs: Double
        /// Row views configured in the frame.
        var configures: Int
        /// Row views the frame made new (not from the pool).
        var created: Int
        /// Full list layouts in the frame (a scroll must make none).
        var reloads: Int
        /// Main-thread CPU per phase, ms: the frame's row patches (ticks), the clip move
        /// (realization, hover), the window's layout pass, its display pass, the commit.
        var patchMs = 0.0, scrollMs = 0.0, layoutMs = 0.0, displayMs = 0.0, commitMs = 0.0
    }

    let sidebar: SidebarView
    let model: SidebarModel
    let window: NSWindow
    let count: Int
    /// The workspaces as built, for ticks.
    private(set) var rows: [SidebarWorkspace] = []
    /// Status ticks per frame while scrolling (agents streaming); 0 scrolls a quiet sidebar.
    var ticksPerFrame = 0
    /// Every this many frames a workspace moves to the top (a notification with
    /// `notifications.attention.moveToTop`); 0 never.
    var moveToTopEvery = 0
    private var tick = 0
    var list: SidebarListView { sidebar.list }
    /// Every row view the list has shown, to count the ones a frame made new.
    private var seenViews: Set<ObjectIdentifier> = []
    var clip: NSClipView { sidebar.scrollView.contentView }

    /// - Parameter pointerOverList: the pointer rests over the list's middle while it scrolls, as
    ///   a trackpad scroll has it: every frame moves another row under it (hover follows the scroll).
    /// How the workspaces are grouped.
    enum Shape {
        /// A third in groups of eight, the rest loose (a long-running window).
        case mixed
        /// Every workspace in one open group (a humongous group).
        case oneGroup
        /// One open group per level, `depth` levels deep, the workspaces spread evenly (groups of groups).
        case nested(depth: Int)
        /// `count / perGroup` open groups, each of `perGroup`; all but the first collapsed.
        case manyCollapsed(perGroup: Int)
    }

    init(count: Int, height: CGFloat = 900, pointerOverList: Bool = false, shape: Shape = .mixed) {
        _ = NSApplication.shared
        self.count = count
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ids = (0..<count).map { WorkspaceID("sb-\($0)") }
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
            return w
        }
        var nodes: [SidebarNode] = []
        switch shape {
        case .mixed:
            let grouped = count / 3, perGroup = 8
            var next = 0
            var g = 0
            while next < grouped {
                let members = (next..<min(grouped, next + perGroup)).map(ws)
                nodes.append(.group(SidebarGroup(id: GroupID("sb-g\(g)"), name: "Group \(g)", color: .green, workspaces: members)))
                next += members.count
                g += 1
            }
            nodes += (next..<count).map { .workspace(ws($0)) }
        case .oneGroup:
            nodes = [.group(SidebarGroup(id: GroupID("sb-g0"), name: "Huge group", color: .green, workspaces: (0..<count).map(ws)))]
        case let .nested(depth):
            let per = max(1, count / max(depth, 1))
            var next = 0
            for level in 0..<depth {
                let end = level == depth - 1 ? count : min(count, next + per)
                var group = SidebarGroup(id: GroupID("sb-g\(level)"), name: "Level \(level)", color: .green, workspaces: (next..<end).map(ws))
                if level > 0 { group.parent = GroupID("sb-g\(level - 1)") }
                nodes.append(.group(group))
                next = end
            }
        case let .manyCollapsed(perGroup):
            var next = 0, g = 0
            while next < count {
                let members = (next..<min(count, next + perGroup)).map(ws)
                nodes.append(.group(SidebarGroup(id: GroupID("sb-g\(g)"), name: "Group \(g)", color: .green,
                                                 isCollapsed: g > 0, workspaces: members)))
                next += members.count
                g += 1
            }
        }
        rows = (0..<count).map(ws)
        model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: ids.first)
        sidebar = SidebarView(model: model, design: DesignSettings())
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: height), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        window.orderFrontRegardless()
        if pointerOverList {
            let point = NSPoint(x: window.frame.minX + 130, y: window.frame.midY)
            sidebar.list.hoverCards.pointerLocation = { point }
        }
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        drawFrame()
    }

    func close() { window.close() }

    /// Lays the window out, draws it and commits, as a display frame does.
    func drawFrame() {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func drain() {
        for _ in 0..<4 { RunLoop.main.run(mode: .default, before: Date()) }
    }

    /// Row views in the list (realized and parked): each is a subtree AppKit walks every frame.
    var rowViewsInList: Int { list.subviews.filter { $0 is SidebarRowView }.count }
    /// Rows the visible clip shows now.
    var visibleRows: Int {
        let visible = clip.bounds
        return list.displayed.rows.filter { visible.intersects(list.frame(for: $0)) }.count
    }

    /// The bottom-most clip origin.
    var maxY: CGFloat { max(0, list.frame.height - clip.bounds.height) }

    /// One frame: the clip moves to `y`, then the window draws.
    func frame(to y: CGFloat) -> Frame {
        _ = SidebarPerfCounters.report(reset: true)
        let cpu0 = Self.threadCPU()
        applyTicks()
        if ticksPerFrame > 0 || moveToTopEvery > 0 { drain() } // the row patches land in this frame, as on the display link
        let t1 = Self.threadCPU()
        clip.scroll(to: NSPoint(x: 0, y: y))
        sidebar.scrollView.reflectScrolledClipView(clip)
        let t2 = Self.threadCPU()
        window.contentView?.layoutSubtreeIfNeeded()
        let t3 = Self.threadCPU()
        window.displayIfNeeded()
        let t4 = Self.threadCPU()
        CATransaction.flush()
        let cpu1 = Self.threadCPU()
        let counts = SidebarPerfCounters.report(reset: true)
        var created = 0
        for view in list.rowViews.values where seenViews.insert(ObjectIdentifier(view)).inserted { created += 1 }
        return Frame(cpuMs: (cpu1 - cpu0) * 1_000, configures: counts["row_configures"] ?? 0, created: created,
                     reloads: counts["list_reloads"] ?? 0, patchMs: (t1 - cpu0) * 1_000, scrollMs: (t2 - t1) * 1_000,
                     layoutMs: (t3 - t2) * 1_000, displayMs: (t4 - t3) * 1_000, commitMs: (cpu1 - t4) * 1_000)
    }

    /// This frame's agent ticks: `ticksPerFrame` rows change their status line and age, and every
    /// `moveToTopEvery` frames the last loose workspace moves to the top of the list.
    private func applyTicks() {
        tick += 1
        if ticksPerFrame > 0 {
            var patched: [SidebarWorkspace] = []
            for k in 0..<ticksPerFrame {
                let index = (tick * 7 + k * 31) % rows.count
                rows[index].status = "Streaming reply, \(tick) tokens"
                rows[index].lastActivity = Date()
                patched.append(rows[index])
            }
            _ = model.patchWorkspaces(patched)
        }
        if moveToTopEvery > 0, tick % moveToTopEvery == 0, var section = model.sections.first,
           let last = section.nodes.lastIndex(where: { if case .workspace = $0 { true } else { false } }) {
            let node = section.nodes.remove(at: last)
            let firstLoose = section.nodes.firstIndex { if case .workspace = $0 { true } else { false } } ?? section.nodes.count
            section.nodes.insert(node, at: firstLoose)
            model.sections = [section] + model.sections.dropFirst()
            sidebar.renderNow()
        }
    }

    /// Scrolls top to bottom and back `passes` times, `step` points per frame (a fast trackpad
    /// flick moves 30-60 pt a frame). The first pass down is a warm-up and is dropped. `depth`
    /// turns each pass back that far below the top (nil: at the bottom), so a run's frame count
    /// stops growing with the list.
    func run(step: CGFloat = 40, passes: Int = 2, depth: CGFloat? = nil) -> [Frame] {
        var frames: [Frame] = []
        for pass in 0...max(passes, 0) {
            // Read each step, as `maxY` follows the list's height (ticks can change it mid-pass).
            var bottom: CGFloat { min(maxY, depth ?? maxY) }
            var y: CGFloat = 0
            var down: [Frame] = []
            while y < bottom { y = min(bottom, y + step); down.append(frame(to: y)) }
            while y > 0 { y = max(0, y - step); down.append(frame(to: y)) }
            if pass > 0 || passes == 0 { frames += down }
            drain()
        }
        return frames
    }

    /// Samples this process with `/usr/bin/sample` while it scrolls and prints the heaviest
    /// main-thread frames ("SSB" call tree lines, "SSB-TOP" top of stack). The wait for `sample`
    /// is bounded and off the main thread (`SelfSampler`).
    func profile(seconds: Int = 6, minimum: Int = 25) async throws {
        let (report, rounds) = try await SelfSampler.run(name: "sidebar-scroll", seconds: seconds) { _ in
            try await Task.sleep(for: .milliseconds(500)) // bounded: lets sample attach before the scroll
            var rounds = 0
            let end = Date().addingTimeInterval(TimeInterval(seconds))
            while Date() < end {
                _ = run(step: 40, passes: 0)
                rounds += 1
                await Task.yield()
            }
            return rounds
        }
        guard let text = report else { return print("SIDEBAR-SCROLL-PROFILE no sample output") }
        print("SIDEBAR-SCROLL-PROFILE n=\(count) rounds=\(rounds)")
        let lines = text.components(separatedBy: "\n")
        var inMain = false, printed = 0
        for line in lines {
            if line.contains("Thread_") { inMain = line.contains("main-thread") || line.contains("DispatchQueue_1:") }
            guard inMain, printed < 500 else { continue }
            let trimmed = line.drop { $0 == " " || $0 == "+" || $0 == "!" || $0 == ":" || $0 == "|" }
            guard let n = Int(trimmed.prefix { $0.isNumber }), n >= minimum else { continue }
            print("SSB " + String(line.prefix(260)))
            printed += 1
        }
        if let top = lines.firstIndex(where: { $0.hasPrefix("Sort by top of stack") }) {
            for line in lines[top..<min(lines.count, top + 50)] { print("SSB-TOP " + line) }
        }
    }

    static func threadCPU() -> Double { FrameBudgetCalibration.threadCPU() }

    static func percentile(_ values: [Double], _ p: Double) -> Double { FrameBudgetCalibration.percentile(values, p) }

    static func summary(_ count: Int, _ frames: [Frame]) -> String {
        let cpu = frames.map(\.cpuMs)
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }
        let phases = String(format: " | mean ms patch %.2f scroll %.2f layout %.2f display %.2f commit %.2f | p95 ms scroll %.2f layout %.2f display %.2f commit %.2f",
                            mean(frames.map(\.patchMs)), mean(frames.map(\.scrollMs)), mean(frames.map(\.layoutMs)),
                            mean(frames.map(\.displayMs)), mean(frames.map(\.commitMs)),
                            percentile(frames.map(\.scrollMs), 0.95), percentile(frames.map(\.layoutMs), 0.95),
                            percentile(frames.map(\.displayMs), 0.95), percentile(frames.map(\.commitMs), 0.95))
        let over8 = cpu.filter { $0 > 8 }.count, over16 = cpu.filter { $0 > 16 }.count
        return String(format: "SIDEBAR-SCROLL-BENCH n=%d frames=%d | cpu_ms p50 %.2f p95 %.2f p99 %.2f max %.2f | over8ms %d over16ms %d | configures/frame %.2f created %d reloads %d",
                      count, frames.count, percentile(cpu, 0.5), percentile(cpu, 0.95), percentile(cpu, 0.99), cpu.max() ?? 0,
                      over8, over16, Double(frames.map(\.configures).reduce(0, +)) / Double(max(frames.count, 1)),
                      frames.map(\.created).reduce(0, +), frames.map(\.reloads).reduce(0, +)) + phases
    }
}
