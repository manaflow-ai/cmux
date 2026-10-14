import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-13: the workspace hover card showed at once on every row, so
/// moving the pointer down the sidebar popped a card on each row it passed.
/// It now waits for a native-tooltip dwell (about 1 s): a sweep shows none,
/// a pointer resting on one row shows that row's card, and a pending card is
/// cancelled when the pointer leaves its row.
///
/// The dwell runs on a manual clock the test moves: on the macOS 27 lane a
/// throttled runner stretched each 2 ms sleep of a wall-clock sweep past the
/// dwell, so every row showed its card (`aSweepAcrossFiveRowsShowsNoCard`).
@MainActor @Suite(.serialized) struct SidebarHoverCardDwellTests {
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
        window.contentView = nil
        window.close()
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

    @Test func aDwellOnOneRowShowsExactlyOneCard() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        try #require(rows.count == 5)
        let row = rows[2]
        Self.move(list, to: row.y + row.height / 2)
        try await clock.waitForSleeper()
        // Not yet: the card waits for the dwell.
        clock.advance(by: .milliseconds(300))
        try await Self.settle()
        #expect(coordinator.machine.shownTarget == nil, "the card showed before the dwell")
        // 1.2 s on the row.
        clock.advance(by: .milliseconds(900))
        try await Self.settle(until: { coordinator.machine.shownTarget != nil })
        guard case let .workspace(id) = row.key else { return }
        #expect(coordinator.machine.shownTarget?.id == WorkspaceHoverCardController.targetID(id))
        #expect(coordinator.isShowing(WorkspaceHoverCardController.targetID(id)))
    }

    // MARK: Hover intent (Leo 2026-10-14)

    /// The card on screen, in the list's coordinates.
    private static func cardFrame(_ list: SidebarListView, _ coordinator: HoverCardCoordinator) throws -> NSRect {
        let window = try #require(list.window)
        let screen = NSRectFromString(try #require(coordinator.report["card_frame"]))
        try #require(screen.width > 0 && screen.height > 0, "no card on screen")
        return list.convert(window.convertFromScreen(screen), from: nil)
    }

    /// Rests on row 0 until its card shows.
    private static func dwell(on row: SidebarRow, _ list: SidebarListView, _ coordinator: HoverCardCoordinator,
                              _ clock: ManualClock) async throws -> HoverTargetID {
        guard case let .workspace(id) = row.key else { throw CancellationError() }
        let target = WorkspaceHoverCardController.targetID(id)
        move(list, to: row.y + row.height / 2)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(1_200))
        try await settle(until: { coordinator.isShowing(target) })
        try #require(coordinator.isShowing(target), "the dwell showed no card")
        return target
    }

    /// While a card shows, a pointer heading diagonally into it crosses the
    /// next row: that row must not take the card over (the safe triangle),
    /// and a pointer resting on the card keeps it.
    @Test func headingIntoTheCardAcrossAnotherRowKeepsItOpen() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        try #require(rows.count == 5)
        let first = try await Self.dwell(on: rows[0], list, coordinator, clock)
        let card = try Self.cardFrame(list, coordinator)
        // From the middle of row 0 to a point just inside the card's near edge, 1 pt every 2 ms.
        let start = NSPoint(x: list.bounds.midX, y: rows[0].y + rows[0].height / 2)
        let end = NSPoint(x: card.minX + 4, y: card.midY)
        let length = hypot(end.x - start.x, end.y - start.y)
        var crossed = false
        var slid: [HoverTargetID] = []
        for step in 1...Int(length.rounded(.up)) {
            let t = min(1, CGFloat(step) / length)
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let id = list.hoverCardWorkspace(at: point), WorkspaceHoverCardController.targetID(id) != first { crossed = true }
            list.updateHover(list.convert(point, to: nil))
            if let shown = coordinator.machine.shownTarget?.id, shown != first, slid.last != shown { slid.append(shown) }
            clock.advance(by: .milliseconds(2))
            await Task.yield()
        }
        try #require(crossed, "the path to the card crossed no other row")
        #expect(slid.isEmpty, "a row crossed on the way slid the card to \(slid)")
        // The pointer rests on the card, well past the aim and leave times.
        for _ in 0..<4 {
            try await clock.waitForSleeper()
            clock.advance(by: .milliseconds(400))
            try await Self.settle()
        }
        #expect(coordinator.isShowing(first), "the card closed while the pointer rested on it")
    }

    /// Leaving the card starts a short grace; then the card closes.
    @Test func leavingTheCardStartsTheGraceThenCloses() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        try #require(rows.count == 5)
        let first = try await Self.dwell(on: rows[0], list, coordinator, clock)
        let card = try Self.cardFrame(list, coordinator)
        // Straight right from row 0 into the card (no other row on the way).
        let y = rows[0].y + rows[0].height / 2
        var x = list.bounds.midX
        while x < card.minX + 6 {
            list.updateHover(list.convert(NSPoint(x: x, y: y), to: nil))
            clock.advance(by: .milliseconds(2))
            await Task.yield()
            x += 2
        }
        for _ in 0..<3 {
            try await clock.waitForSleeper()
            clock.advance(by: .milliseconds(400))
            try await Self.settle()
        }
        try #require(coordinator.isShowing(first), "the card closed while the pointer rested on it")
        // The real mouse moves off the card, somewhere no source sees it.
        let away = window.convertPoint(toScreen: list.convert(NSPoint(x: card.maxX + 200, y: card.maxY + 200), to: nil))
        coordinator.pointerLocation = { away }
        // The next look finds the pointer gone: the grace starts then, so the card is still up.
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(200))
        try await Self.settle()
        #expect(coordinator.isShowing(first), "the card closed at once, with no grace")
        try await clock.waitForSleeper()
        for _ in 0..<4 {
            clock.advance(by: .milliseconds(200))
            try await Self.settle()
            if coordinator.machine.shownTarget == nil { break }
            try await clock.waitForSleeper()
        }
        #expect(coordinator.machine.shownTarget == nil, "the card stayed after the pointer left it")
    }

    /// Moving down the list with a little drift toward the card is not heading
    /// into it, even right by the card where the safe triangle is widest: the
    /// card slides to the next row at once, as before the safe triangle.
    @Test func movingDownTheListWithDriftSlidesTheCardAtOnce() async throws {
        let clock = ManualClock()
        let (list, window, coordinator, rows) = Self.sidebar(clock: clock)
        defer { Self.tearDown(list, window, coordinator) }
        try #require(rows.count == 5)
        _ = try await Self.dwell(on: rows[0], list, coordinator, clock)
        guard case let .workspace(next) = rows[1].key else { return }
        let target = WorkspaceHoverCardController.targetID(next)
        // Near the list's right edge, by the card (the safe triangle is widest there), from row 0's
        // middle to row 1's, 3 pt down and 1 pt toward the card every 4 ms.
        var point = NSPoint(x: list.bounds.maxX - 16, y: rows[0].y + rows[0].height / 2)
        let end = rows[1].y + rows[1].height / 2
        var onNextRow: Int?
        var slidAfter: Int?
        var step = 0
        while abs(point.y - end) > 1.5 {
            point.y += end > point.y ? 3 : -3
            point.x += 1
            step += 1
            list.updateHover(list.convert(point, to: nil))
            if onNextRow == nil, let id = list.hoverCardWorkspace(at: point), id == next { onNextRow = step }
            if slidAfter == nil, coordinator.machine.shownTarget?.id == target { slidAfter = step }
            clock.advance(by: .milliseconds(4))
            await Task.yield()
        }
        let reached = try #require(onNextRow, "the path never reached row 1")
        let slid = try #require(slidAfter, "the card stayed on row 0 while the pointer moved down onto row 1")
        #expect(slid - reached <= 2, "the card took \((slid - reached) * 4) ms to slide to row 1")
    }
}
