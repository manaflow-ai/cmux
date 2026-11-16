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
/// waits for that turn after its list wait found the tab. The test hides the tab, lets its turn go, and waits for the
/// end of the move task.
///
/// The wait of 500 ms before the hide is not the step: it gives the creation's reply the time to start the move
/// task. A setup check after it tells if the task had found the tab before the hide: the task then ends at once when
/// the test's turn goes; a task that is still in its list wait ends only at its limit of 10 s.
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

    @Test func aNewTabHiddenWhileItsMoveWaitsForAnEarlierMoveTakesItsSlotWhenItComesBack() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "a-new-tab-hidden-while-its-move-waits")
            let window = try #require(services.windows.active, "setup: the app has no window")
            let pane = try #require(window.focusedPane, "setup: the window has no focused pane")
            let store = services.daemon.store

            // `a b c` in the focused pane, b selected: the new tab goes between b and c.
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
            let known = Set(pane.pane.tabs.map(\.id))

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

            // The test's turn goes: the new tab's move task goes on. A turn after it ends when that task ends.
            held.pass()
            let after = try #require(NewTabSlot.reserve(pane.pane, services: services), "setup: the pane gave no second turn")
            let start = ContinuousClock.now
            _ = await after.earlier?.value
            after.pass()
            let waited = ContinuousClock.now - start
            try #require(waited < .seconds(2),
                         "setup: the new tab's move task ended \(waited) after the test's turn went: it had not found the tab before the hide, so the test did not make the step")
            frames.sample(pane)

            // The daemon refuses the close: the tab comes back.
            store.rejectIntent(close)
            // Past the time in which the app shows a new tab at its slot before its move, and past the move.
            try await frames.sample(pane, for: .seconds(4))

            let seen = frames.all.map { $0.joined() }
            #expect(frames.all.last == ["a", "b", "N", "c"],
                    "settled at \(frames.all.last?.joined() ?? "-"), want abNc; the store's list before the hide: \(before); the strip: \(seen)")
        }
    }
}
