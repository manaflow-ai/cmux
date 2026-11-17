import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextWakeups
import Foundation
import Testing

/// A new tab that a close hid, and that came back (the daemon refused the close, or a program ran in the tab), takes
/// its slot right after the tab it follows, also when the hide came while the tab's move waited for its turn. And a
/// new tab that is gone for good in that time does not hold the moves of the pane's later new tabs.
///
/// A new tab that shows off its place is an order fault that a person can see.
/// `NewTabCloseInterleaveOrderTests.aNewTabWhoseCloseIsUndoneStillTakesItsSlot` hides the tab from a poll, so the
/// hide falls in this step only in some runs. This suite makes the step in each run.
///
/// The step, in `NewTabSlot.place`: the move's task waits until the pane lists the daemon's tab, then waits for the
/// move of the pane's earlier new tab (its turn in the pane's line of moves), then reads the tab again and makes the
/// move. A hide between the first wait's end and the second read is the step.
///
/// How a row holds the step open, with no clock (`theKeptTurn`, `theStep`): it takes a turn in the pane's line of
/// moves before the New Tab action (`NewTabSlot.reserve`, as an earlier new tab does at its press) and keeps it. The
/// new tab's move task then waits for that turn after its list wait found the tab. The row hides the tab and lets its
/// turn go. The move task reads the tab again and finds it hidden: the pane's line of moves counts that read
/// (`WorkLine.targetsHiddenAtTheirTurn`), and the row waits for the count (a set-up wait by the line's own
/// observation with a bound, no poll; not a verdict). Then the
/// row ends the close in its own way and takes the pane's next turn: that turn starts when the move task ended, and
/// the row reads its verdict then. No verdict has a clock. One verdict reads the strip: the row of the settled close
/// expects the strip's sample at the end of the pane's next turn (an event, not a fixed time) to have no new
/// tab. No other verdict reads the strip: the app shows a new tab at its slot for some time before its move, so a
/// strip that is right says nothing of the move, and there the strip's samples are only in the words of a failure.
///
/// The wait of 500 ms before the hide is not the step, and it is a fixed time. Its cause: the creation's reply
/// starts the move task, and the task reads the tab one time before it waits for its turn. No fact of the app tells
/// a test that this read is done. If the task had not found the tab before the hide, the row fails with a line that
/// starts with `setup:` (no result).
///
/// Limits: one new tab (a New Tab page), one pane, a close intent of the store that is never sent (the form of the
/// neighbor test, not a key and not a click), and its refusal by the store's own call. The earlier turn is the test's
/// own, not a second new tab. Each row hides the new tab, which is right of the tabs `a` and `b` and left of `c`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ANewTabHiddenWhileItsMoveWaitsTakesItsSlotTests {
    /// The strip as letters, one entry per change: `a`, `b`, `c` for the three tabs, `N` for the new one (the
    /// stand-in or the daemon's); the tabs that the pane had before them are left out.
    @MainActor private final class Frames {
        private let names: [String: String]
        private let earlier: Set<String>
        private(set) var all: [[String]] = []

        init(names: [String: String], earlier: Set<String>) {
            self.names = names
            self.earlier = earlier
        }

        /// The letter of a tab of the start; nil for each other tab.
        func name(_ id: String) -> String? { names[id] }

        func sample(_ pane: PaneController) {
            let shown: [String] = pane.orderedIDs.compactMap { id in
                if let name = names[id.rawValue] { return name }
                return earlier.contains(id.rawValue) ? nil : "N"
            }
            if all.last != shown { all.append(shown) }
        }

        /// Samples the strip each 5 ms for `time`.
        func sample(_ pane: PaneController, for time: Duration) async throws {
            let end = ContinuousClock.now + time
            while ContinuousClock.now < end {
                sample(pane)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// `a b c` made in the focused pane, b selected (the new tab goes between b and c): the pane, the recorder of its
    /// strip, and the ids of the tabs that the store lists for the pane.
    private static func threeTabs(_ services: AppServices, _ connection: DaemonConnection) async throws -> (PaneController, Frames, Set<String>) {
        services.agentTabs.localHost = AgentSessionRef.host(installID: "a-new-tab-hidden-while-its-move-waits")
        let window = try #require(services.windows.active, "setup: the app has no window")
        let pane = try #require(window.focusedPane, "setup: the window has no focused pane")
        let store = services.daemon.store
        var ids: [String] = []
        for _ in 0..<3 {
            let surface = try await connection.newTab(in: pane.pane.handle).surface
            try await PasswordManagerRouteTests.until { store.tab(surface: surface) != nil }
            ids.append(try #require(store.tab(surface: surface), "setup: the store has no tab for a new surface").id)
        }
        let made = Set(ids)
        try await PasswordManagerRouteTests.until({ made.isSubset(of: Set(pane.orderedIDs.map(\.rawValue))) },
                                                  report: { "strip: \(pane.orderedIDs.map(\.rawValue))" })
        pane.select(TabID(ids[1]))
        let frames = Frames(names: [ids[0]: "a", ids[1]: "b", ids[2]: "c"], earlier: Set(pane.orderedIDs.map(\.rawValue)))
        return (pane, frames, Set(pane.pane.tabs.map(\.id)))
    }

    /// What the work of the pane's next turn saw at its start.
    @MainActor private final class NextTurn {
        var listAtStart: String?
    }

    /// The fires of the two limits of a new tab's move (its list wait, its turn) that the wakeup ledger has recorded.
    private static func limitFires() -> UInt64 {
        WakeupLedger.shared.snapshot().filter { $0.owner == "NewTabSlot.listed" || $0.owner == "NewTabSlot.answer" }.reduce(0) { $0 + $1.count }
    }

    /// A new tab whose move task waits for the test's kept turn.
    private struct KeptTurn {
        let pane: PaneController
        let frames: Frames
        /// The turn of an earlier move of the pane that has not ended: the test keeps it.
        let held: WorkTurn<ActionWorkFailure?>
        /// The new tab (the daemon's tab of the New Tab page).
        let tab: TabModel
        /// The store's list with the new tab, as letters.
        let before: String
        /// The fires of the two limits before the New Tab action, and when the test took its turn.
        let fires: UInt64
        let taken: ContinuousClock.Instant
    }

    /// `a b c`, a kept turn in the pane's line of moves, the New Tab action, and the pane lists the daemon's tab of
    /// the new tab as its last tab: the tab's move waits for the kept turn. Each check here is a set-up check.
    private static func theKeptTurn(_ services: AppServices, _ connection: DaemonConnection) async throws -> KeptTurn {
        let (pane, frames, known) = try await threeTabs(services, connection)
        let held = try #require(NewTabSlot.reserve(pane.pane, services: services), "setup: the pane gave no turn in its line of moves")
        let fires = limitFires(), taken = ContinuousClock.now

        try #require(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)),
                     "setup: the New Tab action was refused")
        frames.sample(pane)
        let model = pane.pane
        let listed: @MainActor @Sendable () -> Bool = { model.tabs.contains { !known.contains($0.id) && !ProvisionalTab.isProvisional($0.id) } }
        if !listed() { await ObservationDeadline(owner: "ANewTabHiddenWhileItsMoveWaitsTakesItsSlotTests.listed").until(listed, limit: .seconds(4)) }
        // Not the step, and a fixed time: the creation's reply starts the move task, and the task reads the tab
        // before it waits for its turn. No fact of the app tells a test that this read is done (the suite's comment).
        try await frames.sample(pane, for: .milliseconds(500))
        let tab = try #require(pane.pane.tabs.first { !known.contains($0.id) && !ProvisionalTab.isProvisional($0.id) },
                               "setup: the pane does not list the daemon's tab of the creation")
        let before = pane.pane.tabs.map { $0.id == tab.id ? "N" : (frames.name($0.id) ?? "-") }.joined()
        try #require(pane.pane.tabs.last?.id == tab.id,
                     "setup: the new tab is not the last tab of the store's list (\(before)): its move was made, the test's turn did not hold it")
        return KeptTurn(pane: pane, frames: frames, held: held, tab: tab, before: before, fires: fires, taken: taken)
    }

    /// The step, made (the suite's comment): the kept turn, the hide of the new tab by a close that is never sent,
    /// the kept turn let go, and the wait until the pane's line of moves counted the move task's read of the hidden
    /// tab. Each check here is a set-up check. The close's transaction comes with the kept turn.
    private static func theStep(_ services: AppServices, _ connection: DaemonConnection) async throws -> (KeptTurn, ClientTransactionID) {
        let kept = try await theKeptTurn(services, connection)
        let pane = kept.pane

        // The hide: a close of the new tab that is never sent.
        let close = try #require(services.daemon.store.intendClose([kept.tab.surface]), "setup: the close found no tab")
        kept.frames.sample(pane)
        let time = ContinuousClock.now - kept.taken
        try #require(time < .seconds(8), "setup: the test kept its turn for \(time), near the turn's own limit of 10 s")

        // The test's turn goes: the new tab's move task goes on and reads the tab again. The tab is hidden.
        kept.held.pass()
        let line = pane.placements
        let counted: @MainActor @Sendable () -> Bool = { line.targetsHiddenAtTheirTurn == 1 }
        if !counted() { await ObservationDeadline(owner: "ANewTabHiddenWhileItsMoveWaitsTakesItsSlotTests.counted").until(counted, limit: .seconds(4)) }
        try #require(counted(), "setup: the new tab's move task did not read the tab while it was hidden (count \(line.targetsHiddenAtTheirTurn), after 4 s): it had not found the tab before the hide, so the test did not make the step")
        kept.frames.sample(pane)
        return (kept, close)
    }

    @Test func aNewTabHiddenWhileItsMoveWaitsForAnEarlierMoveTakesItsSlotWhenItComesBack() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (step, close) = try await Self.theStep(services, connection)
            let pane = step.pane, frames = step.frames, tab = step.tab

            // The daemon refuses the close: the tab comes back. A turn after the move task's starts when that task ended.
            services.daemon.store.rejectIntent(close)
            let after = try #require(NewTabSlot.reserve(pane.pane, services: services), "setup: the pane gave no second turn")
            _ = await after.earlier?.value
            after.pass()
            frames.sample(pane)
            let list = pane.pane.tabs.map { $0.id == tab.id ? "N" : (frames.name($0.id) ?? "-") }.joined()
            #expect(list.filter { $0 != "-" } == "abNc",
                    "when the new tab's move task ended the store lists \(list) (want a, b, N, c in that order); the store's list before the hide: \(step.before); the strip: \(frames.all.map { $0.joined() })")
        }
    }

    /// The close settles in the gap: no move, and the pane's next turn goes on.
    ///
    /// The test keeps a turn, as in the first row, and closes the new tab by the product's close (a click on the
    /// tab's close button; a New Tab page has no close question). It waits until the store says that the close
    /// settled (the store's own observation with a bound, no poll), lets its turn go, and takes the pane's next turn
    /// with a work of its own. That work starts when the new tab's move task ended: its start is the event, and no
    /// expect has a clock. A move task that a limit ended shows as a fire of that limit's timer in the wakeup ledger.
    ///
    /// The row has no fixed wait: a move task that is still in its list wait when the close settles ends by the same
    /// settled close. It is green before the mend of this suite's first row too: a guard of the mend's branch for a
    /// settled close.
    @Test func aNewTabWhoseCloseSettlesWhileItsMoveWaitsIsNotMovedAndThePanesNextTurnGoesOn() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (pane, frames, known) = try await Self.threeTabs(services, connection)
            let store = services.daemon.store
            let held = try #require(NewTabSlot.reserve(pane.pane, services: services), "setup: the pane gave no turn in its line of moves")
            let fires = Self.limitFires(), taken = ContinuousClock.now

            try #require(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)),
                         "setup: the New Tab action was refused")
            let model = pane.pane
            let listed: @MainActor @Sendable () -> Bool = { model.tabs.contains { !known.contains($0.id) && !ProvisionalTab.isProvisional($0.id) } }
            if !listed() { await ObservationDeadline(owner: "ANewTabHiddenWhileItsMoveWaitsTakesItsSlotTests.listed").until(listed, limit: .seconds(4)) }
            let tab = try #require(pane.pane.tabs.first { !known.contains($0.id) && !ProvisionalTab.isProvisional($0.id) },
                                   "setup: the pane does not list the daemon's tab of the creation")
            let surface = tab.surface, id = tab.id

            // The close of the new tab, sent to the daemon; then its end.
            pane.handle(.close(TabID(id), source: .mouse))
            let settled: @MainActor @Sendable () -> Bool = { store.closedLately(surface) }
            if !settled() { await ObservationDeadline(owner: "ANewTabHiddenWhileItsMoveWaitsTakesItsSlotTests.settled").until(settled, limit: .seconds(4)) }
            try #require(settled(), "setup: the store does not say that the close of the new tab settled, after 4 s")
            try #require(!pane.pane.tabs.contains { $0.id == id }, "setup: the store says that the close settled, and the pane still lists the tab")
            let kept = ContinuousClock.now - taken
            try #require(kept < .seconds(8), "setup: the test kept its turn for \(kept), near the turn's own limit of 10 s")

            // The test's turn goes. The pane's next turn: its work starts after the new tab's move task ended.
            held.pass()
            let after = try #require(NewTabSlot.reserve(pane.pane, services: services), "setup: the pane gave no second turn")
            let next = NextTurn(), earlier = after.earlier
            let work: ActionWork = Task { @MainActor in
                _ = await earlier?.value
                next.listAtStart = pane.pane.tabs.map { frames.name($0.id) ?? ($0.id == id ? "N" : "-") }.joined()
                return nil
            }
            after.fill(work)
            _ = await after.place.value
            frames.sample(pane)

            let list = try #require(next.listAtStart, "setup: the work of the pane's next turn did not start")
            let now = Self.limitFires()
            #expect(now == fires, "\(now - fires) limits of a new tab's move fired (want 0: the settled close ends the move task, not a limit of 10 s)")
            #expect(list.filter { $0 != "-" } == "abc", "at the start of the pane's next turn the store lists \(list) (want a, b, c in that order, and no new tab)")
            let moves = store.pendingIntents.filter { if case .moveTab = $0 { true } else { false } }
            #expect(moves.isEmpty, "the store has \(moves.count) moves that wait for the daemon's answer (want 0: a closed tab is not moved)")
            #expect(frames.all.last == ["a", "b", "c"], "the strip at the end: \(frames.all.last?.joined() ?? "-"), want abc; the strip: \(frames.all.map { $0.joined() })")
        }
    }

    /// The new tab leaves its pane with no close of the person (the daemon closes it, as when its program ends) while
    /// its move waits for its turn. No close names the tab, so nothing can give it back. The
    /// move task does not wait for such a tab, so the move of the pane's next new tab does not wait for a limit of
    /// 10 s.
    ///
    /// The row keeps a turn as the first row does. The test's own connection closes the new tab at the daemon, and
    /// the row waits until the pane no longer lists it (the store's own observation with a bound, no poll). Then it
    /// lets its turn go and takes the pane's next turn, which starts when the move task ended. The verdict has no
    /// clock: the pane's line of moves counts no second wait, and no limit of a new tab's move fired (the wakeup
    /// ledger).
    ///
    /// Red before the mend: the move task asked only if the pane was there, so it waited for the tab until its limit:
    /// one second wait, and the timer's fire in the ledger. The red row takes up to 10 s.
    ///
    /// A fired limit with no second wait is no result (`setup:`): the move task had not found the tab before the
    /// daemon closed it, so its first wait ran to its limit. That wait is not this row's step.
    @Test func aNewTabThatLeftItsPaneWithNoCloseDoesNotHoldThePanesNextTurn() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let kept = try await Self.theKeptTurn(services, connection)
            let pane = kept.pane, frames = kept.frames, model = pane.pane, line = pane.placements, id = kept.tab.id

            // The daemon closes the new tab. The store has no close of it.
            try await connection.closeTab(kept.tab.surface)
            let gone: @MainActor @Sendable () -> Bool = { !model.tabs.contains { $0.id == id } }
            if !gone() { await ObservationDeadline(owner: "ANewTabHiddenWhileItsMoveWaitsTakesItsSlotTests.gone").until(gone, limit: .seconds(4)) }
            try #require(gone(), "setup: the pane lists the new tab 4 s after the daemon closed it")
            let time = ContinuousClock.now - kept.taken
            try #require(time < .seconds(8), "setup: the test kept its turn for \(time), near the turn's own limit of 10 s")

            // The test's turn goes. A turn after the move task's starts when that task ended.
            kept.held.pass()
            let after = try #require(NewTabSlot.reserve(pane.pane, services: services), "setup: the pane gave no second turn")
            _ = await after.earlier?.value
            after.pass()
            frames.sample(pane)

            let fired = Self.limitFires() - kept.fires, waits = line.targetsHiddenAtTheirTurn
            try #require(!(fired > 0 && waits == 0), "setup: \(fired) limits of a new tab's move fired with no second wait: the move task had not found the tab before the daemon closed it, so the test did not make the step")
            #expect(waits == 0 && fired == 0,
                    "the move task waited \(waits) times for a tab that no close names, and \(fired) limits of a new tab's move fired (want 0 and 0: nothing can give the tab back)")
            let list = model.tabs.map { $0.id == id ? "N" : (frames.name($0.id) ?? "-") }.joined()
            #expect(list.filter { $0 != "-" } == "abc", "at the start of the pane's next turn the store lists \(list) (want a, b, c in that order, and no new tab)")
            let moves = services.daemon.store.pendingIntents.filter { if case .moveTab = $0 { true } else { false } }
            #expect(moves.isEmpty, "the store has \(moves.count) moves that wait for the daemon's answer (want 0: a tab that is gone is not moved)")
        }
    }

    /// The daemon closes the new tab while a close of the person hides it, and then that close is refused: the tab is
    /// gone, no close names it, and no close settled. The new tab's move task waits for the tab then (its second
    /// wait). That wait ends when no close that is not settled names the tab, not at its
    /// limit of 10 s, so the move of the pane's next new tab does not wait for that limit.
    ///
    /// The row makes the step as the first row does. Then the test's own connection closes the new tab at the daemon,
    /// and then the tab `c`. The store hides the new tab, so no list of the store tells when the store has the
    /// daemon's close of it. The daemon's events come in order: the store has that close when the pane no longer
    /// lists `c` (the store's own observation with a bound, no poll). Then the close of the person is refused
    /// (`DaemonStore.rejectIntent`, as in the first row), and the test takes the pane's next turn, which starts when
    /// the move task ended. The verdict has no clock: no limit of a new tab's move fired (the wakeup ledger), and the
    /// pane's line of moves counts one second wait.
    ///
    /// Red before the mend: the refusal gave no tab back, so it changed no list, and nothing told the move task. Its
    /// wait ended by its limit, and the timer's fire is in the ledger. The red row takes up to 10 s.
    ///
    /// Limits: the refusal is the store's call with no command, and the row does not read what the daemon answers to
    /// a close of a tab that it closed before.
    @Test func aNewTabThatTheDaemonClosedWhileACloseHidItDoesNotHoldThePanesNextTurn() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (step, close) = try await Self.theStep(services, connection)
            let pane = step.pane, frames = step.frames, model = pane.pane, line = pane.placements
            let c = try #require(model.tabs.first { frames.name($0.id) == "c" }, "setup: the pane does not list the tab c")
            let witness = c.id

            // The daemon closes the new tab, which the store hides, and then the tab c, which the store lists.
            try await connection.closeTab(step.tab.surface)
            try await connection.closeTab(c.surface)
            let gone: @MainActor @Sendable () -> Bool = { !model.tabs.contains { $0.id == witness } }
            if !gone() { await ObservationDeadline(owner: "ANewTabHiddenWhileItsMoveWaitsTakesItsSlotTests.witness").until(gone, limit: .seconds(4)) }
            try #require(gone(), "setup: the pane lists the tab c 4 s after the daemon closed it, so the store does not have the daemon's close of the new tab")
            let time = ContinuousClock.now - step.taken
            try #require(time < .seconds(6), "setup: the test took \(time) to this point, near the limit of 10 s of the move task's wait")
            try #require(line.targetsHiddenAtTheirTurn == 1 && Self.limitFires() == step.fires,
                         "setup: before the refusal the line counts \(line.targetsHiddenAtTheirTurn) second waits and \(Self.limitFires() - step.fires) limits fired (want 1 and 0: the move task waits for its tab)")

            // The close is refused. The tab does not come back: the daemon closed it. A turn after the move task's
            // starts when that task ended.
            services.daemon.store.rejectIntent(close)
            let after = try #require(NewTabSlot.reserve(pane.pane, services: services), "setup: the pane gave no second turn")
            _ = await after.earlier?.value
            after.pass()
            frames.sample(pane)

            let now = Self.limitFires()
            #expect(now == step.fires, "\(now - step.fires) limits of a new tab's move fired (want 0: the move task's wait ends when no close names the tab, not at its limit of 10 s)")
            #expect(line.targetsHiddenAtTheirTurn == 1, "the pane's line of moves counts \(line.targetsHiddenAtTheirTurn) second waits (want 1: no wait after the close ended)")
            let list = model.tabs.map { $0.id == step.tab.id ? "N" : (frames.name($0.id) ?? "-") }.joined()
            #expect(list.filter { $0 != "-" } == "ab", "at the start of the pane's next turn the store lists \(list) (want a, b: the daemon closed the new tab and c)")
            let moves = services.daemon.store.pendingIntents.filter { if case .moveTab = $0 { true } else { false } }
            #expect(moves.isEmpty, "the store has \(moves.count) moves that wait for the daemon's answer (want 0: a tab that is gone is not moved)")
        }
    }
}
