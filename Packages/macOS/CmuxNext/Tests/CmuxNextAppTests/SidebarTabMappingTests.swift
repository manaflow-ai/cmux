import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Testing

/// The workspace hover card needs each tab's own folder and live status, rather than the
/// workspace's front-tab summary.
@MainActor
struct SidebarTabMappingTests {
    @Test func mapsEachTabFolderAndStatus() throws {
        let store = DaemonStore()
        let tabs = [
            TabSnapshot(surface: 1, title: "shell", cwd: "/Users/leo/Projects/api"),
            TabSnapshot(surface: 2, title: "agent", cwd: "/Users/leo"),
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

        #expect(row.tabs.map(\.cwd) == ["~/Projects/api", "~"])
        #expect(row.tabs.first?.status == .idle)
        #expect(row.tabs.last?.status == .working)
    }
}
