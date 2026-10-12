import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// What toasts say (op-next-theme toasts): a closed New Tab page is "New Tab", never its
/// `about:blank` address, and an error never shows a raw workspace id.
@MainActor
struct ToastCopyTests {
    /// A pane with a New Tab page (a conversation tab still on the blank page) and a browser tab
    /// on `about:blank` that never reported a title.
    private static func store() -> DaemonStore {
        let store = DaemonStore()
        let newTab = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        let blank = TabSnapshot(surface: 2, kind: .browser, title: "", url: "about:blank")
        let pane = PaneSnapshot(id: 1, tabs: [newTab, blank])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return store
    }

    @Test func theClosedNewTabToastSaysNewTab() throws {
        let store = Self.store()
        let pages = InternalPageTabStore()
        for surface in [1, 2] {
            let tab = try #require(store.tab(surface: surface))
            let message = MiscHandlerStrings.tabClosed(CloseUndoToasts.title(of: tab, pages: pages))
            #expect(message == MiscHandlerStrings.tabClosed(Strings.untitledBrowser))
            #expect(!message.contains("about:blank"))
        }
    }

    /// The "no workspace" refusal (a toast, the socket's `not_found`) is a sentence, not an id.
    @Test func theNoWorkspaceMessageHasNoRawID() {
        let id = "ws_01JABCDEF0123456789"
        let message = RefusalStrings.noWorkspace(id)
        #expect(!message.contains(id))
        #expect(!message.isEmpty)
        #expect(!RefusalStrings.noWorkspaceGroup("wg_01JABCDEF").contains("wg_01JABCDEF"))
    }
}
