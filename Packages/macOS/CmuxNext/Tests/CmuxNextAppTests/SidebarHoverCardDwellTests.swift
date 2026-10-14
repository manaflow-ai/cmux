import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-13: the workspace hover card showed at once on every row, so
/// moving the pointer down the sidebar popped a card on each row it passed.
/// It now waits for a native-tooltip dwell (about 1 s): a sweep shows none,
/// a pointer resting on one row shows that row's card, and a pending card is
/// cancelled when the pointer leaves its row.
@MainActor @Suite(.serialized) struct SidebarHoverCardDwellTests {
    /// Five workspaces with a folder and a branch each (cards with facts),
    /// in an ordered-front window, on a coordinator that hit-tests that
    /// window.
    private static func sidebar() -> (SidebarListView, NSWindow, HoverCardCoordinator, [SidebarRow]) {
        _ = NSApplication.shared
        let workspaces = (1...5).map {
            SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace-\($0)", directory: "~/Projects/site-\($0)", branch: "main")
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                 activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let coordinator = HoverCardCoordinator()
        coordinator.appIsActive = { true }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        // A still real mouse: the coordinator takes each pointer event's own point.
        coordinator.pointerLocation = { .zero }
        list.hoverCards = coordinator
        window.contentView = list
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        window.orderFrontRegardless()
        list.reload(animated: false)
        let rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
        return (list, window, coordinator, rows)
    }

    private static func move(_ list: SidebarListView, to y: CGFloat) {
        list.updateHover(list.convert(NSPoint(x: list.bounds.midX, y: y), to: nil))
    }

    private static func tearDown(_ list: SidebarListView, _ window: NSWindow, _ coordinator: HoverCardCoordinator) {
        coordinator.dismiss(.action)
        window.contentView = nil
        window.close()
    }

    @Test func aSweepAcrossFiveRowsShowsNoCard() async throws {
        let (list, window, coordinator, rows) = Self.sidebar()
        defer { Self.tearDown(list, window, coordinator) }
        try #require(rows.count == 5)
        var shown: [HoverTargetID] = []
        // A normal-speed sweep: 1 pt every 2 ms (500 pt/s), top of the first row to the end of the last.
        var y = try #require(rows.first).y
        let end = try #require(rows.last).maxY
        while y < end {
            Self.move(list, to: y)
            if let id = coordinator.machine.shownTarget?.id, shown.last != id { shown.append(id) }
            try await Task.sleep(for: .milliseconds(2))
            y += 1
        }
        // The pointer leaves the sidebar: nothing that was pending shows later.
        Self.move(list, to: list.bounds.maxY + 40)
        try await Task.sleep(for: .milliseconds(1_200))
        if let id = coordinator.machine.shownTarget?.id, shown.last != id { shown.append(id) }
        #expect(shown.isEmpty, "the sweep showed \(shown.count) cards: \(shown)")
    }

    @Test func aDwellOnOneRowShowsExactlyOneCard() async throws {
        let (list, window, coordinator, rows) = Self.sidebar()
        defer { Self.tearDown(list, window, coordinator) }
        try #require(rows.count == 5)
        let row = rows[2]
        Self.move(list, to: row.y + row.height / 2)
        // Not yet: the card waits for the dwell.
        try await Task.sleep(for: .milliseconds(300))
        #expect(coordinator.machine.shownTarget == nil, "the card showed before the dwell")
        try await Task.sleep(for: .milliseconds(900))
        // 1.2 s on the row; allow a loaded runner a moment more.
        for _ in 0..<50 where coordinator.machine.shownTarget == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case let .workspace(id) = row.key else { return }
        #expect(coordinator.machine.shownTarget?.id == WorkspaceHoverCardController.targetID(id))
        #expect(coordinator.isShowing(WorkspaceHoverCardController.targetID(id)))
    }
}
