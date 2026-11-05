import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing
import CmuxNextWakeupsTestSupport

/// Leo 2026-11-01: "i also feel like the hover previews disappear way too quick when my cursor is
/// over them?" A workspace card follows its row. A sidebar change nobody asked for (an agent's
/// status, a workspace another client made) waited only while the pointer was over the rows, so
/// it showed the moment the pointer went onto the card: the rows above moved, the card followed
/// its row out from under the pointer, and it hid. The pointer on the card now holds the rows
/// still too; the change shows once the pointer has left both the rows and the card.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarHoverCardHoldsRowsTests {
    private static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    private static func drawnOrder(_ list: SidebarListView) -> [CmuxNextSidebar.WorkspaceID] {
        list.displayed.rows.compactMap { if case let .workspace(id) = $0.key { id } else { nil } }
    }

    /// Lets a due deadline reach the coordinator (its timer hops back to the main actor).
    private static func settle(until done: () -> Bool, tries: Int = 500) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<tries where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aChangeNobodyAskedForWaitsWhileThePointerIsOnTheCard() async throws {
        _ = NSApplication.shared
        let model = SidebarModel(sections: Self.sections([1, 2, 3, 4, 5]))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let clock = ManualClock()
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.mouseButtonDown = { false }
        coordinator.windowNumberAt = { [weak window] _ in window?.windowNumber }
        // A still real mouse: the coordinator takes each pointer event's own point.
        coordinator.pointerLocation = { .zero }
        let list = sidebar.list
        list.hoverCards = coordinator
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.renderNow()
        list.reload(animated: false, fromModel: true)
        defer {
            coordinator.dismiss(.action)
            coordinator.cardWindow?.closeAfterTest()
            window.closeAfterTest()
        }

        // Rest on the third row until its card shows.
        let rows = list.displayed.rows.filter { if case .workspace = $0.key { true } else { false } }
        try #require(rows.count == 5)
        let row = rows[2]
        list.updateHover(list.convert(NSPoint(x: list.bounds.midX, y: (row.y + row.maxY) / 2), to: nil))
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        try await Self.settle(until: { coordinator.machine.shownTarget != nil })
        let shown = try #require(coordinator.machine.shownTarget, "resting on the row showed no card")
        let panel = try #require(coordinator.panel)
        let card = panel.cardFrame

        // From the row onto its card: the list sees the pointer leave at a point on the card.
        var pointerOverRows = false
        list.pointerIsOverList = { _ in pointerOverRows }
        let onCard = CGPoint(x: card.minX + 8, y: card.maxY - 8)
        coordinator.pointerMoved(to: onCard)
        let exit = try #require(NSEvent.enterExitEvent(with: .mouseExited, location: window.convertPoint(fromScreen: onCard),
                                                       modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                       context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        list.mouseExited(with: exit)
        #expect(coordinator.isShowing(shown.id), "moving from the row onto its card hid it")

        // Another client adds a workspace at the top while the pointer rests on the card.
        let before = Self.drawnOrder(list)
        model.sections = Self.sections([0, 1, 2, 3, 4, 5])
        sidebar.renderNow()
        #expect(Self.drawnOrder(list) == before, "rows moved while the pointer rested on the card")
        #expect(panel.cardFrame == card, "the card moved out from under the pointer: \(card) -> \(panel.cardFrame)")

        // The pointer still rests there: the card is still up after its leave window.
        try await clock.waitForSleeper()
        clock.advance(by: HoverCardTiming.reshowWindow + .milliseconds(100))
        try await Self.settle(until: { !coordinator.isShowing(shown.id) }, tries: 5)
        #expect(coordinator.isShowing(shown.id), "the card hid with the pointer on it (\(coordinator.machine.phase))")

        // Off the card, away from the sidebar: the card goes, and the held change shows.
        pointerOverRows = false
        coordinator.pointerMoved(to: CGPoint(x: card.maxX + 60, y: card.midY))
        #expect(coordinator.machine.shownTarget == nil, "the card stayed after the pointer left it")
        #expect(Self.drawnOrder(list) == model.sections[0].workspaces.map(\.id), "the held change did not show once the card hid")
    }
}
