import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// u9696: a click on a tab's row in the shown workspace card selects that tab through the
/// sidebar's one tab selection intent (`SidebarIntent.selectTab`, as a tab row in the list does),
/// closes the card, and never reaches the window under the card. A click on the card off the tab
/// rows only closes it, as before.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardTabClickTests {
    private static func sidebar(clock: ManualClock) -> (SidebarListView, NSWindow, HoverCardCoordinator, SidebarModel, SidebarRow) {
        _ = NSApplication.shared
        let tabs = [
            SidebarTab(id: TabID("tab-a"), title: "claude", state: .waiting, detail: "claude: Approve edit", pane: 0),
            SidebarTab(id: TabID("tab-b"), title: "zsh", detail: "~/fun/site", pane: 0),
            SidebarTab(id: TabID("tab-c"), title: "Pull requests", kind: .browser, detail: "github.com", pane: 1, flags: [.playing]),
        ]
        let workspace = SidebarWorkspace(id: WorkspaceID("ws-1"), title: "skibidi", tabs: tabs)
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(workspace)])], activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        coordinator.pointerLocation = { .zero }
        list.hoverCards = coordinator
        window.contentView = list
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        window.orderFrontRegardless()
        list.reload(animated: false)
        let row = list.displayed.rows.first { if case .workspace = $0.key { true } else { false } }!
        return (list, window, coordinator, model, row)
    }

    static func click(at screen: CGPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: window.convertPoint(fromScreen: screen), modifierFlags: [],
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                        clickCount: 1, pressure: 1))
    }

    @Test func clickingATabRowOnTheCardSelectsThatTab() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, model, row) = Self.sidebar(clock: clock)
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        _ = try await WorkspaceHoverCardScrollTests.showCard(list, coordinator, clock, row: row)
        let body = try #require(coordinator.panel?.glass.contentView.subviews.compactMap { $0 as? WorkspaceHoverCardView }.first)
        #expect(body.tabLines.count == 5, "the card lists no tabs: \(body.lines)")
        let frame = try #require(body.tabRowFrameOnScreen(at: 2))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        coordinator.pointerMoved(to: point)
        let delivered = coordinator.handleMonitoredEvent(try Self.click(at: point, in: window))
        #expect(delivered == nil, "the click on the tab row went on to the window under the card")
        #expect(intents.contains(.selectTab(workspace: WorkspaceID("ws-1"), tab: TabID("tab-c"))), "\(intents)")
        #expect(coordinator.machine.shownTarget == nil, "the card stayed after its tab was picked")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }

    @Test func aClickOffTheTabRowsOnlyEndsTheCard() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, model, row) = Self.sidebar(clock: clock)
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        _ = try await WorkspaceHoverCardScrollTests.showCard(list, coordinator, clock, row: row)
        // The click lands on the row in the sidebar, not on the card.
        let onRow = window.convertPoint(toScreen: list.convert(NSPoint(x: list.bounds.midX, y: (row.y + row.maxY) / 2), to: nil))
        let delivered = coordinator.handleMonitoredEvent(try Self.click(at: onRow, in: window))
        #expect(delivered != nil)
        #expect(!intents.contains { if case .selectTab = $0 { true } else { false } })
        #expect(coordinator.machine.shownTarget == nil)
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }
}
