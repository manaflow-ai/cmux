import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// `home.show` (TOP-SECTION-ITEMS-ARE-PAGES): its purpose is the view
/// change, so a run from any origin shows the Home page in the active
/// window; the window keeps naming its workspace under the page. The page
/// needs no store home workspace.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct HomeShowActionTests {
    static let homeKey = "6b1d2c3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e"

    /// The scripted daemon reports a second workspace of kind `home`, and the
    /// window files it beside the shown one.
    static func addHome(_ harness: ViewChangePermissionTests.Harness) async throws {
        harness.daemon.state.tree.withLock { tree in
            tree.workspaces.append(TopologyDaemon.Workspace(id: 90, key: homeKey, screens: [
                TopologyDaemon.Screen(id: 91, layout: .leaf(92), panes: [TopologyDaemon.Pane(id: 92, tabs: [93])]),
            ], name: "Home", kind: "home"))
            tree.revision += 1
        }
        await harness.services.daemon.store.refresh()
        try await ViewChangePermissionTests.waitUntil {
            harness.services.windows.registry.members(of: harness.window.state.id).count == 2
        }
    }

    @Test(arguments: ["cli", "script", "user"])
    func homeShowShowsTheHomePageFromAnyOrigin(origin: String) async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        try await Self.addHome(harness)
        #expect(harness.window.state.workspaceID == TopologyDaemon.firstKey)
        try await ViewChangePermissionTests.run(harness, "home.show", origin: origin)
        try await ViewChangePermissionTests.waitUntil { harness.window.shownTopPage == .home }
        #expect(harness.window.state.page == .home)
        #expect(harness.window.state.workspaceID == TopologyDaemon.firstKey, "the workspace stays under the page")
    }

    @Test func homeShowNeedsNoHomeWorkspace() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        try await ViewChangePermissionTests.run(harness, "home.show", origin: "cli")
        try await ViewChangePermissionTests.waitUntil { harness.window.shownTopPage == .home }
        #expect(harness.window.state.page == .home)
    }
}
