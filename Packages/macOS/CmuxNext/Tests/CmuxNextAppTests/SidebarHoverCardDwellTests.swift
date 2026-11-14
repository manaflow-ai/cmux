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

    /// Returns once the pending card's delay timer and its settle timer both sleep on the clock: an
    /// advance before the settle timer registers would move its deadline (review F3 of #38872).
    private static func bothTimersAsleep(_ clock: ManualClock) async throws {
        try await clock.waitForSleeper()
        for _ in 0..<10_000 where clock.sleeperCount < 2 { await Task.yield() }
        try #require(clock.sleeperCount >= 2, "the settle timer never slept (\(clock.sleeperCount) sleepers)")
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

    /// Leo 2026-11-01: "i need these hover previews to appear a hell of a lot faster than they do
    /// now". A pointer that stops on a row gets its card once it stops (`HoverCardTiming.settleQuiet`),
    /// not after the whole delay; the sweep above, which never stops, still gets none.
    @Test func aPointerThatStopsOnARowGetsItsCardOnceItStops() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        let row = try #require(rows.dropFirst(2).first)
        Self.move(list, to: (row.y + row.maxY) / 2)
        try await Self.bothTimersAsleep(clock)
        clock.advance(by: HoverCardTiming.settleQuiet - .milliseconds(10))
        try await Self.settle()
        #expect(coordinator.machine.shownTarget == nil, "the card showed before the pointer had stopped")
        clock.advance(by: .milliseconds(20))
        try await Self.settle(until: { coordinator.machine.shownTarget != nil })
        #expect(coordinator.machine.shownTarget != nil,
                "a pointer resting \(HoverCardTiming.settleQuiet + .milliseconds(10)) on the row got no card (\(coordinator.machine.phase))")
    }

    /// A hand easing onto a row: its last move is slower than `HoverCardTiming.settleSpeed`, and the
    /// card shows on that move, with no wait at all.
    @Test func aPointerEasingOntoARowGetsItsCardOnTheSlowMove() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        let row = try #require(rows.dropFirst(2).first)
        let middle = (row.y + row.maxY) / 2
        // 6 pt in 8 ms (750 pt/s): still moving, no card.
        Self.move(list, to: middle - 7)
        clock.advance(by: .milliseconds(8))
        Self.move(list, to: middle - 1)
        #expect(coordinator.machine.shownTarget == nil, "a pointer moving at 750 pt/s got a card")
        // 1 pt in 8 ms (125 pt/s): it has stopped.
        clock.advance(by: .milliseconds(8))
        Self.move(list, to: middle)
        #expect(coordinator.machine.shownTarget != nil, "a pointer easing onto the row at 125 pt/s got no card (\(coordinator.machine.phase))")
    }

    /// One move reported twice (crossing between strips, the same event is one strip's exit and the
    /// next one's entry) is one sample: the repeat reads as no motion, and a pointer passing at
    /// 875 pt/s got its card (review F1 of #38872).
    @Test func oneMoveReportedTwiceIsNotAPointerAtRest() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        let row = try #require(rows.dropFirst(2).first)
        let middle = (row.y + row.maxY) / 2
        Self.move(list, to: middle - 7)
        clock.advance(by: .milliseconds(8))
        Self.move(list, to: middle)
        clock.advance(by: .milliseconds(1))
        Self.move(list, to: middle)
        #expect(coordinator.machine.shownTarget == nil, "the same move reported twice opened the card")
    }

    /// A delay set in `sidebar.hoverCards.delay`, even the default's 400 ms, is a fixed wait: a stop
    /// opens nothing before it (review F2 of #38872).
    @Test func aDelayTheUserSetWaitsItsWholeTime() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        coordinator.delaySettles = { false }
        let row = try #require(rows.dropFirst(2).first)
        Self.move(list, to: (row.y + row.maxY) / 2)
        try await clock.waitForSleeper()
        clock.advance(by: HoverCardTiming.settleQuiet + .milliseconds(10))
        try await Self.settle()
        #expect(coordinator.machine.shownTarget == nil, "a set delay opened the card once the pointer stopped")
        clock.advance(by: DesignSettings.shared.hoverCardDelay)
        try await Self.settle(until: { coordinator.machine.shownTarget != nil })
        #expect(coordinator.machine.shownTarget != nil, "no card after the set delay")
    }

    /// Leo 2026-11-07 (#39684): "this is one of the more important hover previews because it's how
    /// we navigate into the thing ... So I don't want it to disappear as quickly as other ones
    /// would." The card touches its row; the pointer moving from the row onto it keeps it, and
    /// leaving the row and the card keeps it for the leave grace, then it fades out and is clear
    /// within the fade. (This takes back Lawrence 2026-10-19, "We need it to instantly disappear
    /// with fade opacity when I mouse out", which stays as Debug Settings
    /// `sidebar.hoverCards.workspaceLeave` = Hides at once.)
    @Test func leavingTheRowAndTheCardFadesTheCardOutAfterTheLeaveGrace() async throws {
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

        // Off the card to the right, away from the sidebar: the card lingers on this move, and
        // the fade starts when its leave grace ends.
        coordinator.pointerMoved(to: CGPoint(x: card.maxX + 60, y: card.midY))
        #expect(coordinator.isShowing(shown.id), "the card went (\(coordinator.machine.phase)) on the move off it, with no leave grace")
        try await WorkspaceHoverCardScrollTests.waitOutLeaveGrace(coordinator, clock)
        #expect(coordinator.machine.shownTarget == nil, "the card stayed (\(coordinator.machine.phase)) past its leave grace")
        #expect(!panel.isShowingCard, "the fade did not start when the leave grace ended")
        try await Self.expectClearWithinTheFade(panel)

        // Again, leaving the row itself (not onto the card): the same grace. First the reshow
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
        #expect(coordinator.isShowing(shown.id), "the card went (\(coordinator.machine.phase)) as the pointer left the sidebar, with no leave grace")
        try await WorkspaceHoverCardScrollTests.waitOutLeaveGrace(coordinator, clock)
        #expect(coordinator.machine.shownTarget == nil, "the card stayed (\(coordinator.machine.phase)) past its leave grace")
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
