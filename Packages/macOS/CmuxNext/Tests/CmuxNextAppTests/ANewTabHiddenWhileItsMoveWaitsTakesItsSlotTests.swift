import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import CmuxNextWakeups
import Foundation
import Testing

/// A new tab that a close hid, and that came back (the daemon refused the close, or a program ran in the tab), takes
/// its slot right after the tab it follows, also when the hide came while the tab's move waited for its turn.
///
/// Decision of 2026-11-16: a new tab that shows off its place is an order fault that a person can see.
/// `NewTabCloseInterleaveOrderTests.aNewTabWhoseCloseIsUndoneStillTakesItsSlot` hides the tab from a poll, so the
/// hide falls in this step only in some runs. This suite makes the step in each run.
///
/// The step, in `NewTabSlot.place`: the move's task waits until the pane lists the daemon's tab, then waits for the
/// move of the pane's earlier new tab (its turn in the pane's line of moves), then reads the tab again and makes the
/// move. A hide between the first wait's end and the second read is the step.
///
/// How the test holds the step open, with no clock: it takes a turn in the pane's line of moves before the New Tab
/// action (`NewTabSlot.reserve`, as an earlier new tab does at its press) and keeps it. The new tab's move task then
/// waits for that turn after its list wait found the tab. The test hides the tab and lets its turn go. The move task
/// reads the tab again and finds it hidden: the pane's line of moves counts that read
/// (`WorkLine.targetsHiddenAtTheirTurn`), and the test waits for the count (a set-up wait by the shared poll, not a
/// verdict). Then the test gives the tab back and takes the pane's next turn: that turn starts when the move task
/// ended, and the test reads the store's list then. That read is the verdict, and it has no clock.
///
/// The wait of 500 ms before the hide is not the step: it gives the creation's reply the time to start the move
/// task. If the task had not found the tab before the hide, the count does not rise, and the test fails with a
/// line that starts with `setup:` (no result). The 4 s of strip samples at the end are a guard with a fixed time.
///
/// Limits: one new tab (a New Tab page), one pane, a close intent of the store that is never sent (the form of the
/// neighbor test, not a key and not a click). The earlier turn is the test's own, not a second new tab.
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

    @Test func aNewTabHiddenWhileItsMoveWaitsForAnEarlierMoveTakesItsSlotWhenItComesBack() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (pane, frames, known) = try await Self.threeTabs(services, connection)
            let store = services.daemon.store

            // The turn of an earlier move of the pane that has not ended: the test keeps it.
            let held = try #require(NewTabSlot.reserve(pane.pane, services: services), "setup: the pane gave no turn in its line of moves")
            let taken = ContinuousClock.now

            try #require(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)),
                         "setup: the New Tab action was refused")
            frames.sample(pane)
            let listed = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < listed, !pane.pane.tabs.contains(where: { !known.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }) {
                frames.sample(pane)
                try await Task.sleep(for: .milliseconds(1))
            }
            // Not the step: the creation's reply starts the move task in this time.
            try await frames.sample(pane, for: .milliseconds(500))
            let tab = try #require(pane.pane.tabs.first { !known.contains($0.id) && !ProvisionalTab.isProvisional($0.id) },
                                   "setup: the pane does not list the daemon's tab of the creation")
            let before = pane.pane.tabs.map { $0.id == tab.id ? "N" : (frames.name($0.id) ?? "-") }.joined()
            try #require(pane.pane.tabs.last?.id == tab.id,
                         "setup: the new tab is not the last tab of the store's list (\(before)): its move was made, the test's turn did not hold it")

            // The hide: a close of the new tab that is never sent.
            let close = try #require(store.intendClose([tab.surface]), "setup: the close found no tab")
            frames.sample(pane)
            let kept = ContinuousClock.now - taken
            try #require(kept < .seconds(8), "setup: the test kept its turn for \(kept), near the turn's own limit of 10 s")

            // The test's turn goes: the new tab's move task goes on and reads the tab again. The tab is hidden.
            held.pass()
            let line = pane.placements
            try await PasswordManagerRouteTests.until({ line.targetsHiddenAtTheirTurn == 1 }, report: {
                "setup: the new tab's move task did not read the tab while it was hidden (count \(line.targetsHiddenAtTheirTurn)): it had not found the tab before the hide, so the test did not make the step"
            })
            frames.sample(pane)

            // The daemon refuses the close: the tab comes back. A turn after the move task's starts when that task ended.
            store.rejectIntent(close)
            let after = try #require(NewTabSlot.reserve(pane.pane, services: services), "setup: the pane gave no second turn")
            _ = await after.earlier?.value
            after.pass()
            let list = pane.pane.tabs.map { $0.id == tab.id ? "N" : (frames.name($0.id) ?? "-") }.joined()
            #expect(list.filter { $0 != "-" } == "abNc",
                    "when the new tab's move task ended the store lists \(list) (want a, b, N, c in that order); the store's list before the hide: \(before)")

            // A guard, with a fixed time: past the time in which the app shows a new tab at its slot before its move.
            try await frames.sample(pane, for: .seconds(4))

            let seen = frames.all.map { $0.joined() }
            #expect(frames.all.last == ["a", "b", "N", "c"],
                    "settled at \(frames.all.last?.joined() ?? "-"), want abNc; the store's list before the hide: \(before); the strip: \(seen)")
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
}
