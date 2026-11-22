import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// Tip smoke red at b732874bf5e3 (STATUS 4852): Cmd-T on a browser page, then Cmd-W. The New Tab
/// page stayed and the browser page never came back. Cmd-T shows the page as a stand-in tab
/// (`pending_tab_...`) until the daemon's reply names the store's tab, and the store then swaps
/// them in one step. The pane's strip shows the store one observation step later, so a Cmd-W in
/// that step still named the stand-in, which the store no longer listed: Close Tab found no tab
/// and closed nothing, silently. On the fleet (hog +15 GB) a Cmd-W 30 ms after Cmd-T hit it in 3
/// of 3 rounds, on the tip and on the last smoke-green build. Runs the app's Close Tab against a
/// same-tree cmux-tui daemon, in the turn the store swaps the tabs, before any observation step.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdWOnReplacedStandInTests {
    @Test func cmdWInTheStepTheStoreReplacedTheNewTabStandInClosesTheStoresTab() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle

            // The browser page Cmd-T is pressed on, selected.
            let page = try await connection.newFrontendBrowserTab(url: "https://example.com/", engine: .webkit, in: handle, activate: false)
            try await PinnedPageTests.until({ store.tab(surface: page.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            let pageID = try #require(store.tab(surface: page.surface)).id
            pane.select(TabID(pageID))

            // The tab the daemon makes for Cmd-T's New Tab page, listed (its tab-added came first).
            let record = AgentSessionRef(host: AgentSessionRef.host(installID: "cn-cmdw-stand-in"), hostName: "This Mac",
                                         session: nil, harness: nil)
            let made = try await connection.request(NewConversationTabRequest(agentSession: record, pane: handle))
            try await PinnedPageTests.until({ store.tab(surface: made.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            let madeID = try #require(store.tab(surface: made.surface)).id

            // Cmd-T (AgentTabStore.open): the New Tab page shows as a stand-in, selected.
            let standIn = ProvisionalTab()
            let transaction = ClientTransactionID.generate()
            store.intend(.createTab(pane: handle, provisional: standIn.conversation(ConversationTabRef(agentSession: record))),
                         transaction: transaction)
            pane.selectWhenReported(surface: standIn.surface)
            try #require(pane.stripModel.selectedID?.rawValue == standIn.id, "the stand-in is not selected")

            // The reply's turn, as AgentTabStore.open runs it: the selection waits for the store's tab
            // (moveSelection), then the reply names it and it replaces the stand-in in the records.
            pane.pendingSelect.surface = made.surface
            ProvisionalTab.created(transaction, surface: made.surface, in: store)
            store.noteSettledAtNextSnapshot(transaction)
            #expect(store.tab(id: standIn.id) == nil, "the store still lists the stand-in")
            // The strip has not caught up yet (its observation runs in a later turn): Cmd-W now.
            try #require(pane.stripModel.selectedID?.rawValue == standIn.id,
                         "the strip already selects \(pane.stripModel.selectedID?.rawValue ?? "-"): the test no longer reaches the step")
            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))

            try await PinnedPageTests.until({ store.tab(surface: made.surface) == nil },
                                            within: .seconds(5),
                                            report: { "Cmd-W closed nothing: the pane holds \(store.pane(handle)?.tabs.map(\.id) ?? []), the New Tab tab is \(madeID)" })
            #expect(store.tab(surface: page.surface) != nil, "Cmd-W closed the browser page")
        }
    }

    /// The same step for a browser tab's stand-in: Close Tab asks the page whether it may close
    /// (beforeunload, `BrowserUserClosing`) by the tab's id. Asked with the stand-in's id, which no
    /// page has, the page was never asked and a form the person filled in was lost unasked.
    @Test func cmdWInThatStepAsksTheReplacedBrowserTabsPageFirst() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle
            var asked: [String] = []
            let undo = try #require(services.closedTabs?.undoToasts)
            undo.pageDecidesClose = { _, id in asked.append(id.rawValue); return false }

            // The browser tab the daemon makes for the stand-in, listed.
            let made = try await connection.newFrontendBrowserTab(url: "https://example.com/form", engine: .webkit, in: handle, activate: false)
            try await PinnedPageTests.until({ store.tab(surface: made.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true })
            let madeID = try #require(store.tab(surface: made.surface)).id

            // Its stand-in, selected; then the reply's turn replaces it in the records only.
            let standIn = ProvisionalTab()
            let transaction = ClientTransactionID.generate()
            store.intend(.createTab(pane: handle, provisional: standIn.browser(url: "https://example.com/form", engine: "webkit", profile: nil)),
                         transaction: transaction)
            pane.selectWhenReported(surface: standIn.surface)
            try #require(pane.stripModel.selectedID?.rawValue == standIn.id, "the stand-in is not selected")
            pane.pendingSelect.surface = made.surface
            ProvisionalTab.created(transaction, surface: made.surface, in: store)
            store.noteSettledAtNextSnapshot(transaction)
            try #require(pane.stripModel.selectedID?.rawValue == standIn.id,
                         "the strip already selects \(pane.stripModel.selectedID?.rawValue ?? "-"): the test no longer reaches the step")

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            #expect(asked.contains(madeID), "Close Tab asked \(asked) whether it may close, never the page of \(madeID)")
            try await PinnedPageTests.until({ store.tab(surface: made.surface) == nil }, within: .seconds(5),
                                            report: { "Cmd-W closed nothing: the pane holds \(store.pane(handle)?.tabs.map(\.id) ?? [])" })
        }
    }

    /// Close Other Tabs (Opt-Cmd-T) in that step keeps the selected tab: it names the stand-in the strip shows, and the
    /// store's tab that replaced it survives. Review of #31918 at 92644d5512c: with the store tab's id as the selected tab,
    /// the stand-in counted as another tab and its close resolved to the very tab the person kept.
    @Test func closeOtherTabsInThatStepKeepsTheReplacedTab() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let pane = try #require(services.windows.active?.focusedPane)
            let handle = pane.pane.handle
            let other = try await connection.newFrontendBrowserTab(url: "https://example.com/other", engine: .webkit, in: handle, activate: false)
            let made = try await connection.newFrontendBrowserTab(url: "https://example.com/kept", engine: .webkit, in: handle, activate: false)
            try await PinnedPageTests.until({ [other, made].allSatisfy { store.tab(surface: $0.surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true } })
            let madeID = try #require(store.tab(surface: made.surface)).id

            // The stand-in, selected; the strip does not list the store's tab yet (the store hides a guessed tab).
            let standIn = ProvisionalTab()
            let transaction = ClientTransactionID.generate()
            store.intend(.createTab(pane: handle, provisional: standIn.browser(url: "https://example.com/kept", engine: "webkit", profile: nil)),
                         transaction: transaction)
            pane.selectWhenReported(surface: standIn.surface)
            pane.stripModel.tabs.removeAll { $0.id.rawValue == madeID }
            try #require(pane.stripModel.selectedID?.rawValue == standIn.id && !pane.orderedIDs.contains { $0.rawValue == madeID })
            pane.pendingSelect.surface = made.surface
            ProvisionalTab.created(transaction, surface: made.surface, in: store)
            store.noteSettledAtNextSnapshot(transaction)

            #expect(services.registry.perform("closeOtherTabsInPane", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ store.tab(surface: other.surface) == nil }, within: .seconds(5),
                                            report: { "Close Other Tabs did not close the other tab: \(store.pane(handle)?.tabs.map(\.id) ?? [])" })
            #expect(store.tab(surface: made.surface) != nil, "Close Other Tabs closed the selected tab \(madeID)")
        }
    }
}
