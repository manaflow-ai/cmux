import Testing
@testable import CmuxNextDaemon

/// `DaemonStore.workspace(holdingTab:)`: the workspace that shows a tab, by the tab's durable id.
/// A new chat's leftover goes to that workspace's window (cmux#32276), and a new workspace's first
/// page and seed are found through it, so it follows the tab when the tab moves.
@MainActor
struct WorkspaceHoldingTabTests {
    /// Workspace 1 (pane 10) holds surfaces 1 and 7; workspace 2 (pane 20) holds surface 2.
    private func store() -> DaemonStore {
        let store = DaemonStore()
        let first = ScreenSnapshot(id: 100, layout: .leaf(10), panes: [PaneSnapshot(id: 10, tabs: [TabSnapshot(surface: 1), TabSnapshot(surface: 7)])])
        let second = ScreenSnapshot(id: 200, layout: .leaf(20), panes: [PaneSnapshot(id: 20, tabs: [TabSnapshot(surface: 2)])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [
            WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [first]),
            WorkspaceSnapshot(id: 2, key: nil, name: "workspace-2", screens: [second]),
        ]))
        return store
    }

    @Test func theWorkspaceOfATabIsTheOneWhosePaneHoldsIt() throws {
        let store = store()
        let moved = try #require(store.tab(surface: 7)?.id)
        let other = try #require(store.tab(surface: 2)?.id)
        #expect(store.workspace(holdingTab: moved)?.handle == 1)
        #expect(store.workspace(holdingTab: other)?.handle == 2)
    }

    @Test func aMovedTabNamesItsNewWorkspace() throws {
        let store = store()
        let id = try #require(store.tab(surface: 7)?.id)
        #expect(store.apply(.tabChanged(TabDelta(workspace: 2, screen: 200, pane: 20, surface: 7, index: 1, entity: TabSnapshot(surface: 7)))) == DaemonStore.Followup.none)
        #expect(store.workspace(holdingTab: id)?.handle == 2)
    }

    @Test func anUnknownTabHasNoWorkspace() {
        #expect(store().workspace(holdingTab: "no-such-tab") == nil)
    }
}
