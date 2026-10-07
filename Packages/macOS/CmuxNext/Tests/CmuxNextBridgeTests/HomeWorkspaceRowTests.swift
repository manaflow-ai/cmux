@testable import CmuxNextDaemon
import CmuxNextSidebar
import Testing
@testable import CmuxNextBridge

/// nxdog28 (2026-10-03): "Home" showed twice in the sidebar, as the top
/// section's Home item and as a workspace row. The home workspace
/// (`kind` "home", Home lead) is what the Home item shows, so the workspace
/// list leaves it out.
@MainActor
struct HomeWorkspaceRowTests {
    @Test func theHomeWorkspaceIsNotAWorkspaceRow() throws {
        let store = try BridgeFixture.store()
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let beta = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == "beta" })
        beta.kind = "home"
        let titles = SidebarMapping.shared.sections(store.sidebarSections, machine: machine)[0].workspaces.map(\.title)
        #expect(titles == ["gamma"])
    }

    /// With no Home item in the layout the home workspace is a row again,
    /// so it never becomes unreachable from the sidebar (coordinator).
    @Test func withoutAHomeItemTheHomeWorkspaceIsARowAgain() throws {
        let store = try BridgeFixture.store()
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let beta = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == "beta" })
        beta.kind = "home"
        let sections = SidebarMapping.shared.sections(store.sidebarSections, machine: machine, hidesHomeWorkspace: false)
        #expect(sections[0].workspaces.map(\.title) == ["beta", "gamma"])
    }
}
