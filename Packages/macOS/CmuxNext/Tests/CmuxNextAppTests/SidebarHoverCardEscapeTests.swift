import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-20: moving the pointer off a sidebar workspace to dismiss its hover card took too
/// much travel ("trapped by the preview"). The card sat top-aligned against the row, so right of
/// the row was always the card. Now the row's upper half keeps an empty escape slot beside it that
/// the card never covers, and moving into it dismisses the card at once. The row's lower half
/// still runs straight into the card, so a pointer that wants the card keeps it, and leaving both
/// the row and the card still dismisses it.
@MainActor @Suite(.serialized) struct SidebarHoverCardEscapeTests {
    private static func sidebar(clock: ManualClock) -> (SidebarListView, NSWindow, HoverCardCoordinator, [SidebarRow]) {
        _ = NSApplication.shared
        let workspaces = (1...4).map {
            SidebarWorkspace(id: WorkspaceID("ws-\($0)"), title: "workspace-\($0)", directory: "~/Projects/site-\($0)", branch: "main")
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: workspaces.map { .workspace($0) })],
                                 activeWorkspaceID: nil)
        let list = SidebarListView(model: model)
        // Low on the screen with room above and below, so a small runner's screen never clamps
        // the card off its row's middle.
        let window = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        coordinator.pointerLocation = { .zero }
        list.hoverCards = coordinator
        window.contentView = list
        list.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        window.orderFrontRegardless()
        list.reload(animated: false)
        let rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
        return (list, window, coordinator, rows)
    }

    /// Shows the second row's card; returns the row's frame on screen and the card's.
    private static func showSecondRowCard(_ list: SidebarListView, _ coordinator: HoverCardCoordinator,
                                          _ clock: ManualClock, _ rows: [SidebarRow]) async throws -> (row: CGRect, card: CGRect) {
        try #require(rows.count >= 2)
        let card = try await WorkspaceHoverCardScrollTests.showCard(list, coordinator, clock, row: rows[1])
        guard case .workspace(let id) = rows[1].key, let anchor = list.hoverCardAnchor(for: id) else {
            Issue.record("the second row has no frame on screen")
            return (.zero, card)
        }
        return (anchor, card)
    }

    /// Right of the row's upper half: an empty slot the card never covers; moving there
    /// dismisses the card on that move.
    @Test func movingIntoTheEscapeSlotBesideTheRowDismissesTheCard() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        let (row, card) = try await Self.showSecondRowCard(list, coordinator, clock, rows)
        let slot = CGPoint(x: row.maxX + 24, y: row.maxY - 3)
        #expect(!card.contains(slot), "the card \(card) covers the slot beside its row \(row)")
        coordinator.pointerMoved(to: slot)
        #expect(coordinator.machine.shownTarget == nil, "the card stayed (\(coordinator.machine.phase)) with the pointer in the escape slot")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }

    /// The slot starts at the row's trailing edge, inside the sidebar's own margin: the pointer
    /// there dismisses the card, and moving on within the slot does not bring it back.
    @Test func theEscapeSlotInsideTheSidebarMarginDismissesAndStaysDismissed() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        let (row, _) = try await Self.showSecondRowCard(list, coordinator, clock, rows)
        try #require(row.maxX + 2 < window.frame.maxX, "the row reaches the window's edge; no margin to test")
        for dx in [1, 2] as [CGFloat] {
            let screen = CGPoint(x: row.maxX + dx, y: row.maxY - 3)
            list.updateHover(window.convertPoint(fromScreen: screen))
            #expect(coordinator.machine.shownTarget == nil,
                    "the card showed (\(coordinator.machine.phase)) with the pointer in the slot \(dx) pt right of its row")
        }
        clock.advance(by: HoverCardTiming.reshowWindow + DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        for _ in 0..<20 { await Task.yield() }
        #expect(coordinator.machine.shownTarget == nil, "the card came back with the pointer resting in the slot")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }

    /// Right from the row's lower half the pointer runs straight into the card: every step keeps it.
    @Test func thePathFromTheRowIntoTheCardKeepsIt() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        let (row, card) = try await Self.showSecondRowCard(list, coordinator, clock, rows)
        let shown = try #require(coordinator.machine.shownTarget)
        // The row's lower half, below the card's top edge (the screen may have moved the card).
        let y = min(row.minY + 4, card.maxY - 4)
        try #require(y >= row.minY, "the card \(card) does not reach its row \(row)")
        var x = row.maxX - 6
        while x < card.minX + 24 {
            coordinator.pointerMoved(to: CGPoint(x: x, y: y))
            #expect(coordinator.isShowing(shown.id), "the card went (\(coordinator.machine.phase)) at \(x - row.maxX) pt past the row")
            x += 2
        }
        coordinator.pointerMoved(to: CGPoint(x: card.midX, y: card.midY))
        #expect(coordinator.isShowing(shown.id), "resting on the card hid it")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }

    /// Resting in the slot inside the sidebar's margin (come from the right): the row's card does
    /// not show there after the delay.
    @Test func restingInTheSlotShowsNoCard() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        try #require(rows.count >= 2)
        guard case .workspace(let id) = rows[1].key, let row = list.hoverCardAnchor(for: id) else {
            Issue.record("the second row has no frame on screen")
            return
        }
        try #require(row.maxX + 2 < window.frame.maxX, "the row reaches the window's edge; no margin to test")
        list.updateHover(window.convertPoint(fromScreen: CGPoint(x: row.maxX + 2, y: row.maxY - 3)))
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!(coordinator.panel?.isShowingCard ?? false), "the card showed (\(coordinator.machine.phase)) with the pointer in its slot")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }

    /// Off the row and off the card (past the card's far edge): the card goes on that move.
    @Test func leavingBothTheRowAndTheCardDismissesTheCard() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        let (_, card) = try await Self.showSecondRowCard(list, coordinator, clock, rows)
        coordinator.pointerMoved(to: CGPoint(x: card.midX, y: card.midY))
        coordinator.pointerMoved(to: CGPoint(x: card.maxX + 40, y: card.midY))
        #expect(coordinator.machine.shownTarget == nil, "the card stayed (\(coordinator.machine.phase)) off the row and the card")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }
}
