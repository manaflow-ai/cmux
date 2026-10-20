import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-19 (u3320): "If I open a card, move my mouse over, and start scrolling, the
/// card just disappears." A wheel scroll with the pointer on the shown workspace card belongs to
/// the card: it stays, and the scroll never reaches the sidebar under it. A scroll off the card
/// still ends it, as before.
@MainActor @Suite(.serialized) struct WorkspaceHoverCardScrollTests {
    private static func sidebar(clock: ManualClock) -> (SidebarListView, NSWindow, HoverCardCoordinator, [SidebarRow]) {
        _ = NSApplication.shared
        let workspaces = (1...3).map {
            SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace-\($0)", directory: "~/Projects/site-\($0)", branch: "main")
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                 activeWorkspaceID: nil)
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
        let rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
        return (list, window, coordinator, rows)
    }

    private static func settle(until done: @escaping () -> Bool) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    static func scrollEvent(dy: Int32) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: cg))
    }

    /// Rests on the first row until its card shows; returns the card's frame on screen.
    static func showCard(_ list: SidebarListView, _ coordinator: HoverCardCoordinator, _ clock: ManualClock,
                         row: SidebarRow) async throws -> CGRect {
        list.updateHover(list.convert(NSPoint(x: list.bounds.midX, y: (row.y + row.maxY) / 2), to: nil))
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        try await settle(until: { coordinator.machine.shownTarget != nil })
        try #require(coordinator.machine.shownTarget != nil, "resting on the row showed no card")
        return try #require(coordinator.panel).cardFrame
    }

    @Test func aScrollOnTheCardKeepsItAndNeverReachesTheSidebar() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { coordinator.dismiss(.action); window.contentView = nil; window.close() }
        let card = try await Self.showCard(list, coordinator, clock, row: try #require(rows.first))
        let shown = try #require(coordinator.machine.shownTarget)

        // The pointer moves from the row onto the card, then the wheel turns.
        coordinator.pointerMoved(to: CGPoint(x: card.midX, y: card.midY))
        let delivered = coordinator.handleMonitoredEvent(try Self.scrollEvent(dy: -40))
        #expect(delivered == nil, "the scroll on the card went on to the sidebar under it")
        #expect(coordinator.isShowing(shown.id), "a scroll on the card dismissed it (\(coordinator.machine.phase))")
    }

    @Test func aScrollOffTheCardStillEndsIt() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { coordinator.dismiss(.action); window.contentView = nil; window.close() }
        let row = try #require(rows.first)
        _ = try await Self.showCard(list, coordinator, clock, row: row)
        // The pointer still on the row: the sidebar scrolls and the card goes.
        let delivered = coordinator.handleMonitoredEvent(try Self.scrollEvent(dy: -40))
        #expect(delivered != nil, "a scroll on the row was swallowed")
        #expect(coordinator.machine.shownTarget == nil, "a scroll on the row kept the card")
    }
}
