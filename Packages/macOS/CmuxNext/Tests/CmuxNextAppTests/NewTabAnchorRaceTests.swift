import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// Leo 2026-11-07 (ask-89664a51ba): a new tab from the hotkeys "opens up, like, subsequently", with no "random race condition
/// edge case where ... there's, like, unexpected openings". Two races the review of #37799 left open:
/// - a reopened tab the records list before the strip took it (`pendingSelect.tab`) is the current tab for Cmd-T, as a
///   created tab waiting the same way is (F1);
/// - a stand-in that leaves (closed) in the step an unrelated tab arrives never hands that tab its open's slot (F3).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabAnchorRaceTests {
    /// `a b c` in the focused pane, `b` selected: the three tabs' ids.
    private static func abc(_ services: AppServices, _ connection: DaemonConnection, _ pane: PaneController) async throws -> [String] {
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
        try #require(pane.stripModel.selectedID?.rawValue == ids[1])
        return ids
    }

    /// The pane's strip as names: `a b c`, a new tab by `new`, the tabs from before `a b c` (`earlier`) left out, anything else `?`.
    private static func names(_ pane: PaneController, _ ids: [String], earlier: Set<String>, new: [String: String] = [:]) -> [String] {
        let known = Dictionary(uniqueKeysWithValues: zip(ids, ["a", "b", "c"]))
        return pane.orderedIDs.map(\.rawValue).compactMap { id in known[id] ?? new[id] ?? (earlier.contains(id) ? nil : "?") }
    }

    /// The reopened tab (`a`, listed, not yet selected by the strip) is current: Cmd-T puts the new tab right after it.
    @Test func cmdTRightAfterReopeningATabGoesAfterThatTab() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-newtab-anchor-reopen")
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let ids = try await Self.abc(services, connection, pane)
            let before = Set(pane.pane.tabs.map(\.id)), earlier = before.subtracting(ids)
            // As a reopen leaves it (DaemonClosedHistory: selectWhenReported(tab:)) when the records list the tab a step
            // before the strip's apply takes it.
            pane.pendingSelect.tab = ids[0]
            #expect(TabLifecycle.current(pane) == ids[0], "the current tab is \(TabLifecycle.current(pane) ?? "none"), want the reopened a")
            #expect(services.registry.perform("newTab.default", invocation: ActionInvocation(origin: .user)))
            let settle = ContinuousClock.now + .seconds(4)
            var new: [String: String] = [:]
            while ContinuousClock.now < settle {
                for id in pane.pane.tabs.map(\.id) where !before.contains(id) && !id.hasPrefix(ProvisionalTab.idPrefix) { new[id] = "1" }
                try await Task.sleep(for: .milliseconds(20))
            }
            let order = Self.names(pane, ids, earlier: earlier, new: new)
            #expect(order == ["a", "1", "b", "c"], "settled at \(order.joined(separator: " ")), want a 1 b c")
        }
    }

    /// A Cmd-T's stand-in closes as a script's tab arrives, in one step: the script's tab stays at the end, never in the
    /// stand-in's slot after `b`.
    @Test func aClosedStandInNeverHandsItsSlotToAnUnrelatedTab() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-newtab-anchor-unrelated")
            let window = try #require(services.windows.active)
            let pane = try #require(window.focusedPane)
            let store = services.daemon.store
            let ids = try await Self.abc(services, connection, pane)
            let earlier = Set(pane.pane.tabs.map(\.id)).subtracting(ids)
            // The open of a new tab after `b`, and its stand-in (an intent the daemon never hears, so it stays a stand-in).
            let open = NewTabSuccession.begin(after: ids[1], in: pane.pane, services: services)
            let standIn = ProvisionalTab().browser("about:blank")
            let id = try #require(standIn.tabResourceID?.rawValue)
            store.intend(.createTab(pane: pane.pane.handle, provisional: standIn), transaction: .generate())
            pane.selectWhenReported(surface: standIn.surface)
            try #require(pane.orderedIDs.map(\.rawValue).contains(id), "the stand-in did not show")
            // A second open that waits for its answer: a tab the pane reports meanwhile waits too (it is not shown yet).
            let waiting = NewTabSuccession.begin(after: ids[1], in: pane.pane, services: services)
            NewTabSuccession.made(SurfaceID(rawValue: .max), in: pane.pane, by: waiting) // answered with a tab not reported yet: it waits its order limit
            let surface = try await connection.newTab(in: pane.pane.handle).surface
            try await PasswordManagerRouteTests.until { store.tab(surface: surface) != nil }
            let script = try #require(store.tab(surface: surface)).id
            pane.syncStripFromStore()
            try #require(NewTabSuccession.isOpen(in: pane.pane) && open != nil && waiting != nil, "the opens ended before the check; nothing was proven")
            try #require(!pane.orderedIDs.map(\.rawValue).contains(script), "the script's tab showed before the stand-in closed; nothing was proven")

            // The person closes the stand-in before the daemon made it, while the script's tab waits unshown: one step.
            #expect(store.creations.cancel(tab: id))
            pane.syncStripFromStore()
            var seen: [[String]] = []
            let settle = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < settle {
                let order = Self.names(pane, ids, earlier: earlier, new: [script: "s"])
                if seen.last != order { seen.append(order) }
                try await Task.sleep(for: .milliseconds(5))
            }
            let wrong = seen.filter { $0.contains("s") && $0 != ["a", "b", "c", "s"] }
            #expect(wrong.isEmpty, "the script's tab showed in the closed stand-in's slot: \(seen.map { $0.joined(separator: " ") })")
            #expect(seen.last == ["a", "b", "c", "s"], "settled at \(seen.last?.joined(separator: " ") ?? "-"), want a b c s; frames \(seen.map { $0.joined(separator: " ") })")
            // The closed stand-in was selected: its selection went to the one tab that arrived (review F1 on #38085).
            #expect(pane.stripModel.selectedID?.rawValue != script, "the script's tab took the closed stand-in's selection")
        }
    }
}
