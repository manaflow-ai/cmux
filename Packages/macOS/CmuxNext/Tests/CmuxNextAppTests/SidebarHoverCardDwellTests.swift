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
    /// A clock that moves only when the test advances it.
    nonisolated final class ManualClock: Clock, @unchecked Sendable {
        nonisolated struct Instant: InstantProtocol {
            var offset: Duration
            func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
            func duration(to other: Instant) -> Duration { other.offset - offset }
            static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
        }
        nonisolated private struct Sleeper {
            let id: Int
            let deadline: Instant
            let continuation: CheckedContinuation<Void, any Error>
        }
        private let lock = NSLock()
        private var current = Instant(offset: .zero)
        private var sleepers: [Sleeper] = []
        private var cancelled: Set<Int> = []
        private var nextID = 0

        var now: Instant { lock.withLock { current } }
        var minimumResolution: Duration { .zero }

        @concurrent func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            let id = lock.withLock { nextID += 1; return nextID }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let outcome: Result<Void, any Error>? = lock.withLock {
                        if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                        if deadline <= current { return .success(()) }
                        sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                        return nil
                    }
                    if let outcome { continuation.resume(with: outcome) }
                }
            } onCancel: {
                let sleeper: Sleeper? = lock.withLock {
                    guard let index = sleepers.firstIndex(where: { $0.id == id }) else { cancelled.insert(id); return nil }
                    return sleepers.remove(at: index)
                }
                sleeper?.continuation.resume(throwing: CancellationError())
            }
        }

        /// Waits (bounded) until a timer is asleep on the clock. A timer reads
        /// `now` for its deadline when its task starts, off the main actor:
        /// advancing before then would push its deadline back by the advance.
        func waitForSleeper() async throws {
            for _ in 0..<20 where lock.withLock({ sleepers.isEmpty }) { await Task.yield() }
            for _ in 0..<500 where lock.withLock({ sleepers.isEmpty }) { try await Task.sleep(for: .milliseconds(5)) }
        }

        /// Moves the clock on and wakes every sleeper whose deadline it reached.
        func advance(by duration: Duration) {
            let due: [Sleeper] = lock.withLock {
                current = current.advanced(by: duration)
                let due = sleepers.filter { $0.deadline <= current }
                sleepers.removeAll { $0.deadline <= current }
                return due
            }
            for sleeper in due { sleeper.continuation.resume() }
        }
    }

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
}
