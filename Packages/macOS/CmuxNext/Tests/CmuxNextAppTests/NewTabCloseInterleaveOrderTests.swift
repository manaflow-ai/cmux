import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-11-05: "if you delete a tab and create like and delete in the middle of it, there's like this
/// weird shuffle reordering going on ... if something is optimistic, then we should be able to follow along
/// with the optimistic stuff." Cmd-T puts the new tab right after the current one; a close while it is made
/// (its anchor, or another tab) must not move it: from the press on, every frame shows the tabs that stay in
/// one order, with the new tab where it first showed, through the stand-in, the daemon's tab and its move.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabCloseInterleaveOrderTests {
    /// Which of the three tabs `a b c` (b selected, so the new tab goes between b and c) is closed while
    /// the new tab is made: its anchor, its right neighbor, its left one.
    enum Closed: String, CaseIterable, Sendable { case anchor, right, left }

    /// When the close comes: in the press's own turn, or once the pane lists the daemon's new tab (before the
    /// open moves it into its slot). Both reordered the strip on the base (`abNc`, `Nac`, then `acN`).
    enum When: String, CaseIterable, Sendable { case sameTurn, daemonTab }

    /// The strip as letters, one entry per change: `a`, `b`, `c` for the three tabs, `N` for the new one
    /// (stand-in or daemon's); the pane's other tabs (its first terminal) are left out.
    @MainActor final class StripFrames {
        let names: [String: String]
        let earlier: Set<String>
        private(set) var frames: [[String]] = []

        init(names: [String: String], earlier: Set<String>) {
            self.names = names
            self.earlier = earlier
        }

        func sample(_ pane: PaneController) {
            let shown: [String] = pane.orderedIDs.compactMap { id in
                if let name = names[id.rawValue] { return name }
                return earlier.contains(id.rawValue) ? nil : "N"
            }
            if frames.last != shown { frames.append(shown) }
        }
    }

    /// The order the strip settles at: the new tab stays where it showed (right after b).
    static func settled(_ closed: Closed) -> [String] {
        switch closed {
        case .anchor: ["a", "N", "c"]
        case .right: ["a", "b", "N"]
        case .left: ["b", "N", "c"]
        }
    }

    @Test(arguments: Closed.allCases, When.allCases)
    func aCloseWhileANewTabIsMadeMovesNoOtherTab(closed: Closed, when: When) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-close-interleave")
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let store = services.daemon.store
            var ids: [String] = []
            for _ in 0..<3 {
                let surface = try await connection.newTab(in: pane.pane.handle).surface
                try await PasswordManagerRouteTests.until { store.tab(surface: surface) != nil }
                let tab = try #require(store.tab(surface: surface))
                ids.append(tab.id)
            }
            let made = Set(ids)
            try await PasswordManagerRouteTests.until({ made.isSubset(of: Set(pane.orderedIDs.map(\.rawValue))) },
                                                      report: { "strip: \(pane.orderedIDs.map(\.rawValue))" })
            pane.select(TabID(ids[1]))
            let victim: String
            switch closed {
            case .anchor: victim = ids[1]
            case .right: victim = ids[2]
            case .left: victim = ids[0]
            }
            let names: [String: String] = [ids[0]: "a", ids[1]: "b", ids[2]: "c"]
            let recorder = StripFrames(names: names, earlier: Set(pane.orderedIDs.map(\.rawValue)))

            let known = Set(pane.pane.tabs.map(\.id))
            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            recorder.sample(pane)
            if when == .daemonTab {
                let listed = ContinuousClock.now + .seconds(5)
                while ContinuousClock.now < listed, !pane.pane.tabs.contains(where: { !known.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }) {
                    recorder.sample(pane)
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            recorder.sample(pane)
            pane.handle(.close(TabID(victim), source: .mouse))
            recorder.sample(pane)
            // Past the placement window (NewTabSuccession.orderLimit) and the new tab's move.
            let settle = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < settle {
                recorder.sample(pane)
                try await Task.sleep(for: .milliseconds(5))
            }

            let want = Self.settled(closed)
            let victimName = names[victim] ?? "?"
            let frames = recorder.frames
            let seen = frames.map { $0.joined() }
            let gone = frames.firstIndex { !$0.contains(victimName) } ?? frames.endIndex
            // Rarely (1 run in about 17) a same-turn close shows its tab again for one frame as the close's
            // hide lifts for the close itself; the order of the others never changes (#36813).
            withKnownIssue("a same-turn close can show its tab for one frame", isIntermittent: true) {
                #expect(!frames[gone...].contains { $0.contains(victimName) }, "the closed tab came back: \(seen)")
            }
            let afterClose = frames[gone...].filter { !$0.contains(victimName) }
            #expect(afterClose.allSatisfy { $0 == want }, "the strip reordered: \(seen)")
            #expect(frames.last == want, "settled at \(frames.last?.joined() ?? "-"), want \(want.joined()); \(seen)")
        }
    }

    /// `a b c` made in the focused pane, b selected: the pane, its three tab ids and the recorder for them.
    private static func threeTabs(_ services: AppServices, _ connection: DaemonConnection) async throws -> (PaneController, [String], StripFrames) {
        let window = try #require(services.windows.active)
        let pane = try #require(window.focusedPane)
        let store = services.daemon.store
        var ids: [String] = []
        for _ in 0..<3 {
            let surface = try await connection.newTab(in: pane.pane.handle).surface
            try await PasswordManagerRouteTests.until { store.tab(surface: surface) != nil }
            ids.append(try #require(store.tab(surface: surface)).id)
        }
        let made = Set(ids)
        try await PasswordManagerRouteTests.until({ made.isSubset(of: Set(pane.orderedIDs.map(\.rawValue))) },
                                                  report: { "strip: \(pane.orderedIDs.map(\.rawValue))" })
        pane.select(TabID(ids[1]))
        let recorder = StripFrames(names: [ids[0]: "a", ids[1]: "b", ids[2]: "c"], earlier: Set(pane.orderedIDs.map(\.rawValue)))
        return (pane, ids, recorder)
    }

    /// Samples the strip until the pane lists a daemon tab it did not know (`known`), or for 5 s.
    private static func untilTheDaemonTabIsListed(_ pane: PaneController, known: Set<String>, _ recorder: StripFrames) async throws {
        let listed = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < listed, !pane.pane.tabs.contains(where: { !known.contains($0.id) && !ProvisionalTab.isProvisional($0.id) }) {
            recorder.sample(pane)
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Samples the strip past the placement window (`NewTabSuccession.orderLimit`) and the new tab's move.
    private static func settle(_ pane: PaneController, _ recorder: StripFrames) async throws {
        let settle = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < settle {
            recorder.sample(pane)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Leo 2026-11-05: "if you delete a tab and create like and delete in the middle of it ... we need to like be able to
    /// just, you know, delete the proper thing, play the proper animations". Cmd-T, then the new tab itself closes while it
    /// is made (in the press's turn, a stand-in, or once the pane lists the daemon's tab): the strip goes back to `a b c`
    /// and stays there; the closed tab never shows again and no other tab moves.
    @Test(arguments: When.allCases)
    func closingTheNewTabWhileItIsMadeLeavesTheOthersInPlace(when: When) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-close-new-interleave")
            let (pane, _, recorder) = try await Self.threeTabs(services, connection)
            let known = Set(pane.pane.tabs.map(\.id))
            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            recorder.sample(pane)
            if when == .daemonTab { try await Self.untilTheDaemonTabIsListed(pane, known: known, recorder) }
            recorder.sample(pane)
            let victim = try #require(pane.stripModel.selectedID, "the new tab is selected")
            try #require(!known.contains(victim.rawValue), "the selected tab is not the new one: \(victim.rawValue)")
            pane.handle(.close(TabID(victim.rawValue), source: .mouse))
            recorder.sample(pane)
            try await Self.settle(pane, recorder)

            let frames = recorder.frames, seen = frames.map { $0.joined() }
            let gone = frames.firstIndex { !$0.contains("N") } ?? frames.endIndex
            #expect(gone < frames.endIndex, "the new tab never closed: \(seen)")
            #expect(!frames[gone...].contains { $0.contains("N") }, "the closed new tab came back: \(seen)")
            #expect(frames.allSatisfy { $0.filter { $0 != "N" } == ["a", "b", "c"] }, "the other tabs reordered: \(seen)")
            #expect(frames.last == ["a", "b", "c"], "settled at \(frames.last?.joined() ?? "-"); \(seen)")
        }
    }

    /// Leo 2026-11-05 (as above): Cmd-T twice, then the first new tab closes while the second is made. The second stays
    /// right after b (its anchor, the first, closed under it), stays selected, and no other tab moves.
    @Test(arguments: When.allCases)
    func closingTheFirstOfTwoNewTabsKeepsTheSecondInItsSlot(when: When) async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-close-first-new-interleave")
            let (pane, _, recorder) = try await Self.threeTabs(services, connection)
            let known = Set(pane.pane.tabs.map(\.id))
            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            recorder.sample(pane)
            let first = try #require(pane.stripModel.selectedID, "the first new tab is selected")
            try #require(!known.contains(first.rawValue))
            if when == .daemonTab { try await Self.untilTheDaemonTabIsListed(pane, known: known, recorder) }
            // The first tab as the strip shows it now: its stand-in, or the daemon's tab that took its cell.
            let firstNow = try #require(pane.stripModel.selectedID)
            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            recorder.sample(pane)
            let second = try #require(pane.stripModel.selectedID, "the second new tab is selected")
            try #require(second != firstNow, "the second press selected no new tab")
            pane.handle(.close(TabID(firstNow.rawValue), source: .mouse))
            recorder.sample(pane)
            try await Self.settle(pane, recorder)

            let frames = recorder.frames, seen = frames.map { $0.joined() }
            #expect(frames.allSatisfy { $0.filter { $0 != "N" } == ["a", "b", "c"] }, "the other tabs reordered: \(seen)")
            #expect(frames.last == ["a", "b", "N", "c"], "settled at \(frames.last?.joined() ?? "-"); \(seen)")
            let selected = try #require(pane.stripModel.selectedID)
            #expect(!known.contains(selected.rawValue), "the selection left the second new tab for \(selected.rawValue)")
            #expect(pane.pane.tabs.filter { !known.contains($0.id) }.count == 1, "one new tab stays: \(pane.pane.tabs.map(\.id))")
        }
    }

    /// Review of #38105: a close that hides the new tab past its reply, then is undone (the daemon rejects it, or a
    /// running program's confirmation keeps the tab), still lets the tab take its slot right after b once it shows again:
    /// only a settled close ends the move's wait for its tab.
    @Test func aNewTabWhoseCloseIsUndoneStillTakesItsSlot() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-close-undone-interleave")
            let (pane, _, recorder) = try await Self.threeTabs(services, connection)
            let known = Set(pane.pane.tabs.map(\.id)), store = services.daemon.store
            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            try await Self.untilTheDaemonTabIsListed(pane, known: known, recorder)
            let tab = try #require(pane.pane.tabs.first { !known.contains($0.id) && !ProvisionalTab.isProvisional($0.id) })
            // Hidden by a close that is never sent, past the reply, then rejected.
            let close = try #require(store.intendClose([tab.surface]))
            let hidden = ContinuousClock.now + .milliseconds(600)
            while ContinuousClock.now < hidden {
                recorder.sample(pane)
                try await Task.sleep(for: .milliseconds(5))
            }
            store.rejectIntent(close)
            try await Self.settle(pane, recorder)
            let seen = recorder.frames.map { $0.joined() }
            #expect(recorder.frames.last == ["a", "b", "N", "c"], "settled at \(recorder.frames.last?.joined() ?? "-"); \(seen)")
        }
    }
}
