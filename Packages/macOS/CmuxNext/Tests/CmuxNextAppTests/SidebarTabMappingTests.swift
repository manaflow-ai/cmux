import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Testing
import Foundation

/// The workspace hover card needs each tab's own folder and live status, rather than the
/// workspace's front-tab summary.
@MainActor
struct SidebarTabMappingTests {
    @Test func mapsEachTabFolderAndStatus() throws {
        let store = DaemonStore()
        let home = NSHomeDirectory()
        let tabs = [
            TabSnapshot(surface: 1, title: "shell", cwd: home + "/Projects/api"),
            TabSnapshot(surface: 2, title: "agent", cwd: home),
        ]
        let workspace = WorkspaceSnapshot(id: 1, key: nil, name: "api",
                                          screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [
                                              PaneSnapshot(id: 1, focusedAt: 1, tabs: tabs),
                                          ])])
        store.apply(snapshot: DaemonTree(workspaces: [workspace]))
        let model = try #require(store.workspaces.first)
        let agent = try #require(model.screens.first?.panes.first?.tabs.last)
        agent.agent = AgentStatus(surface: agent.surface, state: .working, updatedAtMs: 1)

        let row = SidebarMapping.shared.row(model, machine: .local)

        #expect(row.tabs.map(\.folder) == ["~/Projects/api", "~"])
        #expect(row.tabs.first?.state == .idle)
        #expect(row.tabs.last?.state == .working)
    }
}
