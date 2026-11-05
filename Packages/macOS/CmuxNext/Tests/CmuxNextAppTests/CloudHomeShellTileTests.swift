@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Testing

/// A pinned or top tile of an unnamed Cloud workspace whose shell idles at its home reads "Terminal", as its sidebar row
/// and its window's titlebar do (#36283, review of #36680 at a75f5fb2). An SSH computer's tile is unchanged.
@MainActor
struct CloudHomeShellTileTests {
    private static func workspace(cwd: String) throws -> WorkspaceModel {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, cwd: cwd)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "workspace-1", screens: [screen])]))
        return try #require(store.workspaces.first)
    }

    @Test func aCloudHomeShellTileReadsTerminal() throws {
        let info = SidebarWorkspaceItems.workspaceInfo(try Self.workspace(cwd: "/home/cmux"), machine: MachineID("vm-1"))
        #expect(info.workspaceRow?.title == "Terminal")
        #expect(info.title == "Terminal")
    }

    @Test func anSSHHomeShellTileIsUnchanged() throws {
        let workspace = try Self.workspace(cwd: "/home/dev")
        let info = SidebarWorkspaceItems.workspaceInfo(workspace, machine: MachineID("ssh-mini"))
        #expect(info.workspaceRow?.title == workspace.displayName)
    }
}
