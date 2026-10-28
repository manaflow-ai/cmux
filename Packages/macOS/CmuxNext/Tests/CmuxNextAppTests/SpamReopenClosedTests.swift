import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Audit A1 (2026-10-28, input-principles.md, hold-shortcuts-ux.md 4): a held or hammered
/// Cmd-Shift-T (`reopenClosedBrowserPanel`) reopens closed items in reverse close order, one per
/// press, none twice and none skipped. Before, each press read the newest closed item from the
/// store, which drops an item only when the daemon's event arrives: presses inside one round trip
/// reopened the same item again (not found, a press lost), and a Cmd-Shift-T right after a Cmd-W
/// reopened an older item than the tab just closed. Runs the app's actions against a same-tree
/// cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SpamReopenClosedTests {
    /// Four closed tabs, then four presses in one turn: the four tabs come back, each once, newest
    /// first, so each lands at the place it closed from and the strip is as it was.
    @Test func fourPressesInOneTurnReopenFourTabsInReverseCloseOrder() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(store.workspaces.first?.screens.first?.panes.first)
            let tag = UUID().uuidString.prefix(6).lowercased()
            let urls = (0..<4).map { "https://example.com/reopen-\(tag)-\($0)" }
            var surfaces: [SurfaceID] = []
            for url in urls {
                surfaces.append(try await connection.newFrontendBrowserTab(url: url, engine: .webkit, in: pane.handle, activate: false).surface)
            }
            try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0) != nil } })
            let before = pane.tabs.map { $0.url ?? $0.id }
            let seen = Set(store.closedItems.map(\.id))
            // Closed one by one, each recorded before the next: four Reopen Closed steps.
            for (index, surface) in surfaces.enumerated() {
                try await connection.closeTab(surface)
                try await PinnedPageTests.until({ Self.fresh(store, seen).count == index + 1 },
                                                report: { "\(Self.fresh(store, seen).count) closed items after close \(index)" })
            }
            let closedIDs = Set(Self.fresh(store, seen).map(\.id))

            let failures = await Self.perform(services, ["reopenClosedBrowserPanel", "reopenClosedBrowserPanel",
                                                         "reopenClosedBrowserPanel", "reopenClosedBrowserPanel"])
            #expect(failures.isEmpty, "four presses in one turn: \(failures)")
            try await PinnedPageTests.until({ urls.allSatisfy { url in pane.tabs.contains { $0.url == url } } },
                                            report: { "open: \(pane.tabs.map { $0.url ?? $0.id })" })
            for url in urls {
                #expect(pane.tabs.filter { $0.url == url }.count == 1, "\(url) reopened \(pane.tabs.filter { $0.url == url }.count) times")
            }
            #expect(pane.tabs.map { $0.url ?? $0.id } == before, "the tabs came back out of reverse close order")
            try await PinnedPageTests.until({ closedIDs.isDisjoint(with: store.closedItems.map(\.id)) },
                                            report: { "still closed: \(closedIDs.intersection(store.closedItems.map(\.id)))" })
        }
    }

    /// An older closed tab in history, then Cmd-W and Cmd-Shift-T in one turn: the tab just closed
    /// comes back, not the older one.
    @Test func cmdShiftTRightAfterCmdWReopensTheTabJustClosed() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first)
            let tag = UUID().uuidString.prefix(6).lowercased()
            let older = "https://example.com/older-\(tag)", current = "https://example.com/current-\(tag)"
            let olderSurface = try await connection.newFrontendBrowserTab(url: older, engine: .webkit, in: paneModel.handle, activate: false).surface
            let currentSurface = try await connection.newFrontendBrowserTab(url: current, engine: .webkit, in: paneModel.handle, activate: false).surface
            try await PinnedPageTests.until({ store.tab(surface: olderSurface) != nil && store.tab(surface: currentSurface) != nil })
            let seen = Set(store.closedItems.map(\.id))
            try await connection.closeTab(olderSurface)
            try await PinnedPageTests.until({ Self.fresh(store, seen).count == 1 }, report: { "the older close was not recorded" })
            let olderItem = try #require(Self.fresh(store, seen).first?.id)

            let pane = try #require(services.paneController(for: paneModel))
            let currentID = try #require(store.tab(surface: currentSurface)).id
            try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue).contains(currentID) })
            pane.select(TabID(currentID))
            try #require(pane.stripModel.selectedID?.rawValue == currentID)

            let failures = await Self.perform(services, ["closeTab", "reopenClosedBrowserPanel"])
            #expect(failures.isEmpty, "Cmd-W then Cmd-Shift-T: \(failures)")
            // The reopen came back (whichever tab it was).
            try await PinnedPageTests.until({ paneModel.tabs.contains { $0.url == current || $0.url == older } },
                                            report: { "open: \(paneModel.tabs.map { $0.url ?? $0.id })" })
            #expect(paneModel.tabs.contains { $0.url == current }, "the tab just closed did not come back")
            #expect(!paneModel.tabs.contains { $0.url == older }, "Cmd-Shift-T reopened the older tab, not the one just closed")
            #expect(store.closedItems.contains { $0.id == olderItem }, "the older close left the history")
        }
    }

    /// Review of the fix: two Cmd-W then two Cmd-Shift-T in one turn, an older closed tab in
    /// history. Both presses wait for closes whose records are not in the store yet: the two tabs
    /// just closed come back at their places, and the older one stays closed.
    @Test func twoCmdWThenTwoCmdShiftTInOneTurnReopenBothTabsJustClosed() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first)
            let tag = UUID().uuidString.prefix(6).lowercased()
            let urls = ["older", "first", "second"].map { "https://example.com/\($0)-\(tag)" }
            var surfaces: [SurfaceID] = []
            for url in urls {
                surfaces.append(try await connection.newFrontendBrowserTab(url: url, engine: .webkit, in: paneModel.handle, activate: false).surface)
            }
            try await PinnedPageTests.until({ surfaces.allSatisfy { store.tab(surface: $0) != nil } })
            let seen = Set(store.closedItems.map(\.id))
            try await connection.closeTab(surfaces[0])
            try await PinnedPageTests.until({ Self.fresh(store, seen).count == 1 }, report: { "the older close was not recorded" })
            let olderItem = try #require(Self.fresh(store, seen).first?.id)
            let before = paneModel.tabs.map { $0.url ?? $0.id }

            let pane = try #require(services.paneController(for: paneModel))
            let lastID = try #require(store.tab(surface: surfaces[2])).id
            try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue).contains(lastID) })
            pane.select(TabID(lastID))
            try #require(pane.stripModel.selectedID?.rawValue == lastID)

            let failures = await Self.perform(services, ["closeTab", "closeTab", "reopenClosedBrowserPanel", "reopenClosedBrowserPanel"])
            #expect(failures.isEmpty, "two Cmd-W then two Cmd-Shift-T: \(failures)")
            try await PinnedPageTests.until({ urls.dropFirst().allSatisfy { url in paneModel.tabs.contains { $0.url == url } } },
                                            report: { "open: \(paneModel.tabs.map { $0.url ?? $0.id })" })
            #expect(!paneModel.tabs.contains { $0.url == urls[0] }, "a Cmd-Shift-T reopened the older tab")
            #expect(paneModel.tabs.map { $0.url ?? $0.id } == before, "the tabs came back out of reverse close order")
            #expect(store.closedItems.contains { $0.id == olderItem }, "the older close left the history")
        }
    }

    /// The closed items stored since `seen`, newest first.
    private static func fresh(_ store: DaemonStore, _ seen: Set<String>) -> [ClosedItem] {
        store.closedItems.filter { !seen.contains($0.id) }
    }

    /// Performs `actions` back to back in one turn as a person's presses, then awaits their work:
    /// every refusal and failure.
    private static func perform(_ services: AppServices, _ actions: [ActionID]) async -> [String] {
        var ran: [ActionID] = []
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork {
                for id in actions where services.registry.perform(id, invocation: ActionInvocation(origin: .user)) { ran.append(id) }
            }
        }
        var failures = refusal.map { [$0] } ?? []
        if ran.count != actions.count { failures.append("ran \(ran) of \(actions)") }
        for task in work { if let failure = await task.value { failures.append(failure.message) } }
        return failures
    }
}
