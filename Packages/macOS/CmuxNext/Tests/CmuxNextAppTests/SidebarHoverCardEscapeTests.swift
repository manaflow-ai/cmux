import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing
import CmuxNextWakeupsTestSupport

/// A sidebar workspace's hover card in the real list. Leo 2026-10-21 ("WHY HAS IT NOT BEEN
/// ALIGNED"): the card's top lines up with its row's top, as Chrome's and Arc's tab cards, and
/// follows the row from row to row; it touches the sidebar's edge. The escape slot beside the
/// row's upper half (#22473, Leo 2026-10-20 "trapped by the preview") is a Debug Settings layout
/// now, covered by `HoverCardEscapeGeometryTests`. A pointer heading into the card keeps it, one
/// going down past the row lets it go, and leaving both the row and the card dismisses it.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarHoverCardEscapeTests {
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
        // the card off its row's top.
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

    private static func settle(until done: @escaping () -> Bool) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<500 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// The card's top is its row's top (Chrome, Arc), not the row's middle.
    @Test func theCardsTopLinesUpWithItsRow() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { window.closeAfterTest(); coordinator.panel?.closeAfterTest() }
        let (row, card) = try await Self.showSecondRowCard(list, coordinator, clock, rows)
        #expect(abs(card.maxY - row.maxY) <= 0.5, "the card's top \(card.maxY) is \(row.maxY - card.maxY) pt below its row's top \(row.maxY)")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }

    /// The hover moves to the next row: the card goes with it, its top on that row's top.
    @Test func theCardFollowsTheHoverToTheNextRow() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { window.closeAfterTest(); coordinator.panel?.closeAfterTest() }
        try #require(rows.count >= 3)
        _ = try await Self.showSecondRowCard(list, coordinator, clock, rows)
        guard case .workspace(let id) = rows[2].key, let next = list.hoverCardAnchor(for: id) else {
            Issue.record("the third row has no frame on screen")
            return
        }
        let target = WorkspaceHoverCardController.targetID(id)
        list.updateHover(list.convert(NSPoint(x: list.bounds.midX, y: (rows[2].y + rows[2].maxY) / 2), to: nil))
        try await Self.settle(until: { coordinator.machine.shownTarget?.id == target })
        try #require(coordinator.machine.shownTarget?.id == target, "the card did not move to the next row (\(coordinator.machine.phase))")
        let card = try #require(coordinator.panel).cardFrame
        #expect(abs(card.maxY - next.maxY) <= 0.5, "the card's top \(card.maxY) is not the next row's top \(next.maxY)")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }

    /// The row ends before the sidebar's drag thumb. Its preview touches the row, not the thumb.
    @Test func theCardTouchesItsWorkspaceRowBeforeTheDragThumb() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { window.closeAfterTest(); coordinator.panel?.closeAfterTest() }
        let (row, card) = try await Self.showSecondRowCard(list, coordinator, clock, rows)
        let edge = window.convertToScreen(list.convert(list.bounds, to: nil)).maxX
        let pixel = 1 / max(window.backingScaleFactor, 1)
        #expect(row.maxX < edge, "the fixture needs a row-to-thumb gutter")
        #expect(card.minX <= row.maxX + 0.001, "a \(card.minX - row.maxX) pt gap from row to preview")
        #expect(row.maxX - card.minX < pixel + 0.001, "overlap must stay below one device pixel")
        #expect(card.minX < edge, "the preview was pushed past the drag thumb")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }

    /// Down from the row's right end, just past the row: the pointer is not heading for the card,
    /// so the card goes on that move instead of catching the pointer.
    @Test func movingDownPastTheRowsRightEndDismissesTheCard() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { window.closeAfterTest(); coordinator.panel?.closeAfterTest() }
        let (row, card) = try await Self.showSecondRowCard(list, coordinator, clock, rows)
        coordinator.pointerMoved(to: CGPoint(x: row.maxX - 2, y: row.minY + 3))
        let shown = try #require(coordinator.machine.shownTarget, "the card went on the row itself")
        // Stay on the list side of the row's edge: with a flush preview, a point to its right
        // is on the preview itself and correctly keeps it open.
        let below = CGPoint(x: row.maxX - 2, y: row.minY - 14)
        try #require(!card.contains(below), "the dismissal path must not enter the preview")
        coordinator.pointerMoved(to: below)
        // Gone, or handed to the row below (the sidebar's margin can still hit-test as that row).
        #expect(coordinator.machine.shownTarget?.id != shown.id,
                "the card stayed (\(coordinator.machine.phase)) with the pointer below its row")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }

    /// Right from the row's lower half the pointer runs straight into the card: every step keeps it.
    @Test func thePathFromTheRowIntoTheCardKeepsIt() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { window.closeAfterTest(); coordinator.panel?.closeAfterTest() }
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

    /// Off the row and off the card (past the card's far edge): the card goes on that move.
    @Test func leavingBothTheRowAndTheCardDismissesTheCard() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { window.closeAfterTest(); coordinator.panel?.closeAfterTest() }
        let (_, card) = try await Self.showSecondRowCard(list, coordinator, clock, rows)
        coordinator.pointerMoved(to: CGPoint(x: card.midX, y: card.midY))
        coordinator.pointerMoved(to: CGPoint(x: card.maxX + 40, y: card.midY))
        #expect(coordinator.machine.shownTarget == nil, "the card stayed (\(coordinator.machine.phase)) off the row and the card")
        try await WorkspaceHoverCardScrollTests.tearDown(window, coordinator)
    }
}
