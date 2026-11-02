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

            // Cmd-T (AgentTabStore.open): the New Tab page shows as a stand-in, selected.
            let record = AgentSessionRef(host: AgentSessionRef.host(installID: "cn-cmdw-stand-in"), hostName: "This Mac",
                                         session: nil, harness: nil)
            let standIn = ProvisionalTab()
            let transaction = ClientTransactionID.generate()
            store.intend(.createTab(pane: handle, provisional: standIn.conversation(ConversationTabRef(agentSession: record))),
                         transaction: transaction)
            pane.selectWhenReported(surface: standIn.surface)
            try #require(pane.stripModel.selectedID?.rawValue == standIn.id, "the stand-in is not selected")

            // The daemon makes the tab. Its tab-added comes first, with no transaction: the store
            // keeps it hidden behind the stand-in until the reply names it (ProvisionalTab.matched).
            let made = try await connection.request(NewConversationTabRequest(agentSession: record, pane: handle))
            try await PinnedPageTests.until({ store.intentLog.entries.contains { $0.transaction == transaction && $0.createdSurface == made.surface } },
                                            report: { "the store did not pair the daemon's tab with the stand-in: \(store.pane(handle)?.tabs.map(\.id) ?? [])" })
            try #require(pane.stripModel.selectedID?.rawValue == standIn.id)

            // The reply's turn, as AgentTabStore.open runs it: the selection is asked to follow
            // (moveSelection), then the store's tab replaces the stand-in.
            pane.selectWhenReported(surface: made.surface)
            ProvisionalTab.created(transaction, surface: made.surface, in: store)
            store.noteSettledAtNextSnapshot(transaction)
            let madeID = try #require(store.tab(surface: made.surface), "the store does not list its tab after the reply").id
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
}
