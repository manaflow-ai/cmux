#if os(iOS)
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// Meta test for Leo's 2026-11-21 report ("i lost connection with cosmic gray ... and my drafted
/// message on ios in the f***ing round composer got lost"): a disconnect, a resync without the
/// tab, a reconnect and a rebuilt screen leave a chat tab's draft as it was.
@MainActor
@Suite struct ComposerDraftReconnectTests {
    @Test func disconnectResyncReconnectAndRebuildKeepTheDraft() throws {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        let drafts = ComposerDraftStore(url: nil)
        let workspace = try #require(store.workspace(id: "ws-cmux"))
        store.macConnection[workspace.macID] = .connected
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux")
        source.drafts = drafts
        source.surface("t-claude").text = "please also check the"

        // Disconnect, then a resync that lists the workspace without the tab.
        store.macConnection[workspace.macID] = .connecting
        var partial = workspace
        partial.tabs.removeAll { $0.id == "t-claude" }
        store.replaceWorkspaces(macID: workspace.macID, with: [partial])
        // Reconnect with the full tree.
        store.macConnection[workspace.macID] = .connected
        store.replaceWorkspaces(macID: workspace.macID, with: [workspace])

        // The screen is rebuilt: a new source (and new chat surfaces) for the same workspace.
        let rebuilt = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux")
        rebuilt.drafts = drafts
        #expect(rebuilt.surface("t-claude").text == "please also check the")

        // A send empties the composer: the draft goes.
        rebuilt.surface("t-claude").text = ""
        #expect(drafts.text(for: ComposerDraftStore.key(macID: workspace.macID, tabID: "t-claude")) == nil)
    }

    @Test func aClosedTabTakesItsDraft() {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        let drafts = ComposerDraftStore(url: nil)
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux")
        source.drafts = drafts
        source.surface("t-claude").text = "never mind"
        source.dropClosedTabs(["t-claude"])
        let macID = store.workspace(id: "ws-cmux")?.macID ?? ""
        #expect(drafts.text(for: ComposerDraftStore.key(macID: macID, tabID: "t-claude")) == nil)
    }
}
#endif
