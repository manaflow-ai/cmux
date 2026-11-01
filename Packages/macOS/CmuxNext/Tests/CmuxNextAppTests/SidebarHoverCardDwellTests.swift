import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing
import CmuxNextWakeupsTestSupport

/// Leo 2026-10-13: the workspace hover card showed at once on every row, so
/// moving the pointer down the sidebar popped a card on each row it passed.
/// It now waits the hover card delay (1300 ms, `HoverCardTiming.showDelay`): a
/// sweep shows none. (The dwell, warm switch, cancel and off checks are the
/// behavior check scripts/cmux-next/hovercard-delay-live.py, cx-23e1f.)
///
/// The dwell runs on a manual clock the test moves: on the macOS 27 lane a
/// throttled runner stretched each 2 ms sleep of a wall-clock sweep past the
/// dwell, so every row showed its card (`aSweepAcrossFiveRowsShowsNoCard`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarHoverCardDwellTests {
    /// Five workspaces with a folder and a branch each (cards with facts),
    /// in an ordered-front window, on a coordinator that hit-tests that
    /// window.
    private static func sidebar(clock: ManualClock) -> (SidebarListView, NSWindow, HoverCardCoordinator, [SidebarRow]) {
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
        let coordinator = HoverCardCoordinator(clock: clock)
        coordinator.appIsActive = { true }
        coordinator.mouseButtonDown = { false }
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

    /// Lets a deadline the clock reached reach the coordinator: the timer
    /// wakes off the main actor and hops back to it. With `done`, waits for
    /// it (bounded); without, gives a due deadline a few turns to land.
    private static func settle(until done: (() -> Bool)? = nil) async throws {
        for _ in 0..<20 { await Task.yield() }
        for _ in 0..<(done == nil ? 3 : 500) where done?() != true { try await Task.sleep(for: .milliseconds(10)) }
    }

    private static func tearDown(_ list: SidebarListView, _ window: NSWindow, _ coordinator: HoverCardCoordinator) {
        coordinator.dismiss(.action)
        coordinator.cardWindow?.closeAfterTest()
        window.contentView = nil
        window.closeAfterTest()
    }

    @Test func aSweepAcrossFiveRowsShowsNoCard() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        try #require(rows.count == 5)
        var shown: [HoverTargetID] = []
        // A normal-speed sweep: 1 pt every 2 ms (500 pt/s), top of the first row to the end of the last.
        var y = try #require(rows.first).y
        let end = try #require(rows.last).maxY
        while y < end {
            Self.move(list, to: y)
            if let id = coordinator.machine.shownTarget?.id, shown.last != id { shown.append(id) }
            if case .pending = coordinator.machine.phase { try await clock.waitForSleeper() }
            clock.advance(by: .milliseconds(2))
            await Task.yield()
            y += 1
        }
        // The pointer leaves the sidebar: nothing that was pending shows later.
        Self.move(list, to: list.bounds.maxY + 40)
        clock.advance(by: .milliseconds(1_200))
        try await Self.settle()
        if let id = coordinator.machine.shownTarget?.id, shown.last != id { shown.append(id) }
        #expect(shown.isEmpty, "the sweep showed \(shown.count) cards: \(shown)")
    }

    /// Lawrence 2026-10-19: "there's a slight delay from when I mouse over the card for our own
    /// workspace and then leave it before it disappears. We need it to instantly disappear with
    /// fade opacity when I mouse out." The card touches its row; the pointer moving from the row
    /// onto it keeps it, and leaving the row and the card starts the fade at once: no grace timer
    /// first, and the card is clear within the fade.
    @Test func leavingTheRowAndTheCardFadesTheCardOutAtOnce() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        let row = try #require(rows.first)
        Self.move(list, to: (row.y + row.maxY) / 2)
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        try await Self.settle(until: { coordinator.machine.shownTarget != nil })
        let shown = try #require(coordinator.machine.shownTarget, "resting on the row showed no card")
        let panel = try #require(coordinator.panel)
        let card = panel.cardFrame

        // From the row straight onto the card (a pointer move over the card, as the coordinator's move monitor reports it): it stays.
        coordinator.pointerMoved(to: CGPoint(x: card.minX + 4, y: card.maxY - 4))
        #expect(coordinator.isShowing(shown.id), "moving from the row onto its card hid it")

        // Off the card to the right, away from the sidebar: the fade starts on this move.
        coordinator.pointerMoved(to: CGPoint(x: card.maxX + 60, y: card.midY))
        #expect(coordinator.machine.shownTarget == nil, "the card waited (\(coordinator.machine.phase)) after the pointer left it")
        #expect(!panel.isShowingCard, "the fade did not start on the move off the card")
        try await Self.expectClearWithinTheFade(panel)

        // Again, leaving the row itself (not onto the card): the same at once. First the reshow
        // window ends (a return within it shows the card at once, with no dwell timer): its timer
        // must be asleep before the clock moves past it, and its deadline must land.
        try await clock.waitForSleeper()
        clock.advance(by: HoverCardTiming.reshowWindow + .milliseconds(100))
        try await Self.settle(until: { coordinator.machine.phase == .idle })
        try #require(coordinator.machine.phase == .idle, "the reshow window did not end: \(coordinator.machine.phase)")
        Self.move(list, to: (row.y + row.maxY) / 2)
        try await clock.waitForSleeper()
        clock.advance(by: DesignSettings.shared.hoverCardDelay + .milliseconds(100))
        try await Self.settle(until: { coordinator.machine.shownTarget != nil })
        try #require(coordinator.machine.shownTarget != nil, "the second rest showed no card")
        list.updateHover(list.convert(NSPoint(x: list.bounds.midX, y: list.bounds.maxY + 40), to: nil))
        #expect(coordinator.machine.shownTarget == nil, "the card waited (\(coordinator.machine.phase)) after the pointer left the sidebar")
        try await Self.expectClearWithinTheFade(panel)
    }

    /// The card is fully clear (alpha 0, or ordered out) within the fade-out duration, plus
    /// scheduling slack for a loaded runner.
    private static func expectClearWithinTheFade(_ panel: HoverCardPanel) async throws {
        let fade = Motion.hoverCards.duration(.fadeOut)
        let start = ContinuousClock.now
        while panel.isVisible, panel.alphaValue > 0.001, ContinuousClock.now - start < .seconds(fade + 1) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let took = ContinuousClock.now - start
        #expect(!panel.isVisible || panel.alphaValue <= 0.001, "the card was still at alpha \(panel.alphaValue)")
        #expect(took <= .seconds(fade + 0.25), "the fade took \(took), past its \(fade) s")
    }
}
