import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Darwin
import QuartzCore
import Testing
import CmuxNextWakeupsTestSupport

/// Lawrence 2026-10-21 ("there's lag here fix it", screen recording 8.15.58 PM): with a workspace
/// hover card open, moving the pointer down and up the sidebar lit each row 2 to 6 frames after
/// the pointer reached it (50 ms p50, 158 ms p95 at 120 Hz). Every row the pointer crosses slides
/// the open card to that row (`HoverCardPanel.present(sliding:)`), and each slide rebuilt the card
/// on the main thread before the row's hover fill could draw. A retarget is one pointer move plus
/// the frame that draws it; it must fit inside half a 60 Hz frame however long the history is.
@MainActor @Suite(.serialized)
struct SidebarHoverCardRetargetBenchTests {
    /// Rows of the history each fake workspace has (the reader's limit is 100).
    static let historyDepth = 100

    private static func history(_ index: Int, now: Date) -> [SidebarTimelineEntry] {
        (0..<historyDepth).map { k in
            let kind = SidebarTimelineEntry.Kind.allCases[(index + k) % SidebarTimelineEntry.Kind.allCases.count]
            let text: String? = kind == .prompt
                ? "Fix the sidebar hover lag in workspace \(index): the card trails the pointer by a few frames, prompt \(k)"
                : kind == .waiting ? "Allow Bash: cmux-ci run --class light --script scripts/ci/package-test-lane.sh (\(k))" : nil
            return SidebarTimelineEntry(kind: kind, date: now.addingTimeInterval(-Double(k * 90 + index)), text: text, agent: "Claude Code")
        }
    }

    private struct Rig {
        let list: SidebarListView
        let window: NSWindow
        let coordinator: HoverCardCoordinator
        let rows: [SidebarRow]
        let clock: ManualClock
    }

    private static func rig(count: Int) -> Rig {
        _ = NSApplication.shared
        let now = Date()
        var workspaces: [SidebarWorkspace] = []
        for i in 0..<count {
            let status: String? = i % 2 == 0 ? "Running fleet tests, step \(i)" : nil
            let activity: StatusIndicatorState = i % 3 == 0 ? .working(progress: nil) : .idle
            let ago = Double(i * 41)
            let workspace = SidebarWorkspace(
                id: WorkspaceID("rt-\(i)"), title: "Workspace \(i) with a longer agent title",
                directory: "~/fun/cmux-worktrees/feature-\(i)", branch: "feat-\(i)", status: status,
                lastActivity: now.addingTimeInterval(-ago), kind: .harness, activity: activity,
                agentBrand: "claude", agentName: "Claude Code")
            workspaces.append(workspace)
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let nodes: [SidebarNode] = workspaces.map { SidebarNode.workspace($0) }
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 260, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = ManualClock()
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.hoverCardsEnabled = { true }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        coordinator.pointerLocation = { .zero }
        list.hoverCards = coordinator
        var histories: [WorkspaceID: [SidebarTimelineEntry]] = [:]
        for (index, workspace) in workspaces.enumerated() { histories[workspace.id] = history(index, now: now) }
        let source: SidebarTimelineSource = { (id: WorkspaceID, limit: Int) -> [SidebarTimelineEntry] in
            Array((histories[id] ?? []).prefix(limit))
        }
        list.hoverCard.timelineSource = source
        window.contentView = list
        list.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        window.orderFrontRegardless()
        list.reload(animated: false)
        let rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
        return Rig(list: list, window: window, coordinator: coordinator, rows: rows, clock: clock)
    }

    private static func tearDown(_ rig: Rig) async throws {
        rig.coordinator.dismiss(.action)
        let start = ContinuousClock.now
        while let panel = rig.coordinator.panel, panel.isVisible, ContinuousClock.now - start < .seconds(3) {
            try await Task.sleep(for: .milliseconds(10))
        }
        rig.window.contentView = nil
        rig.window.close()
    }

    private static func point(_ rig: Rig, _ row: SidebarRow) -> NSPoint {
        rig.list.convert(NSPoint(x: rig.list.bounds.midX, y: (row.y + row.maxY) / 2), to: nil)
    }

    private static func drawFrame(_ rig: Rig) {
        rig.window.displayIfNeeded()
        rig.coordinator.panel?.displayIfNeeded()
        CATransaction.flush()
    }

    static func threadCPUms() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return (Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9) * 1_000
    }

    /// Shows the first row's card, then walks the pointer one row a step down 18 rows and back:
    /// each step's main-thread CPU (the move and the frame that draws it) and the card it shows.
    private static func sweep(_ rig: Rig) async throws -> (ms: [Double], shown: Set<String>) {
        let first = try #require(rig.rows.first)
        rig.list.updateHover(point(rig, first))
        try await rig.clock.waitForSleeper()
        rig.clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<300 where rig.coordinator.machine.shownTarget == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(rig.coordinator.machine.shownTarget != nil, "resting on the first row showed no card")
        drawFrame(rig)
        let path = Array(rig.rows.prefix(18))
        let walk = path + path.reversed().dropFirst()
        var ms: [Double] = []
        var shown: Set<String> = []
        for pass in 0..<3 {
            for row in walk {
                let start = threadCPUms()
                rig.list.updateHover(point(rig, row))
                drawFrame(rig)
                let cost = threadCPUms() - start
                if pass > 0 { ms.append(cost) }
                if let id = rig.coordinator.machine.shownTarget?.id.rawValue { shown.insert(id) }
            }
        }
        return (ms, shown)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// One card retarget (the pointer onto the next row with a card open) costs under half a
    /// 60 Hz frame of main thread, scaled to the runner, and the card follows every row.
    @Test func aRetargetWithACardOpenFitsInsideHalfAFrame() async throws {
        var calibration = FrameBudgetCalibration()
        calibration.checkpoint()
        let rig = Self.rig(count: 18)
        let (ms, shown) = try await Self.sweep(rig)
        try await Self.tearDown(rig)
        calibration.checkpoint()
        let p50 = Self.percentile(ms, 0.5), p95 = Self.percentile(ms, 0.95)
        print(String(format: "HOVER-RETARGET-BENCH steps=%d cpu_ms p50 %.2f p95 %.2f max %.2f | cards %d | %@",
                     ms.count, p50, p95, ms.max() ?? 0, shown.count, calibration.summary))
        #expect(shown.count >= 16, "the card followed only \(shown.count) of 18 rows")
        if let reason = calibration.skipReason { return print("HOVER-RETARGET-BENCH skipped the budget: \(reason)") }
        let budget = calibration.budget(8)
        #expect(p95 < budget, "a hover card retarget took \(p95) ms p95 of main thread, over 8 ms scaled to \(budget) ms")
    }

    /// Where one retarget's time goes: the card body (history read, content, configure) and the
    /// panel's present (fit, place, slide), each timed alone over the same rows.
    @Test func retargetBreakdown() async throws {
        let rig = Self.rig(count: 18)
        _ = try await Self.sweep(rig)
        var body: [Double] = [], present: [Double] = []
        let controller = rig.list.hoverCard
        let panel = try #require(rig.coordinator.panel)
        for row in rig.rows.prefix(18) {
            guard case let .workspace(id) = row.key else { continue }
            let target = WorkspaceHoverCardController.targetID(id)
            var start = Self.threadCPUms()
            let built = try #require(controller.hoverCardBody(for: target))
            body.append(Self.threadCPUms() - start)
            let anchor = try #require(controller.hoverCardAnchor(for: target))
            start = Self.threadCPUms()
            panel.present(body: built.view, anchor: anchor, placement: built.placement, parent: rig.window,
                          themeAnchor: built.themeAnchor, sliding: true, applyTheme: built.applyTheme)
            Self.drawFrame(rig)
            present.append(Self.threadCPUms() - start)
        }
        print(String(format: "HOVER-RETARGET-BREAKDOWN body p50 %.2f p95 %.2f | present+frame p50 %.2f p95 %.2f",
                     Self.percentile(body, 0.5), Self.percentile(body, 0.95),
                     Self.percentile(present, 0.5), Self.percentile(present, 0.95)))
        try await Self.tearDown(rig)
    }
}
