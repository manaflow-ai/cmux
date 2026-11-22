import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// A workspace's content mounts its panes in the same turn it is created
/// or changed, so the first frame a window draws of it has its tab strips
/// and content. Switching to a workspace that was not kept warm (Home, a
/// new workspace) drew one blank frame with no tab strip: the layout view
/// mirrored the layout model through an async observation, a turn after
/// the model had the screens (op-next-layout, #17485).
@MainActor
struct WorkspaceFirstFrameTests {
    private static let key = WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02")

    @Test func aPopulatedWorkspaceMountsItsPanesWhenItsContentIsCreated() throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try BridgeTreeFixture.tree())
        let workspace = try #require(services.daemon.store.workspaces.first { $0.key == Self.key })
        let state = WindowState(workspaceID: workspace.id)
        let controller = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
        defer { controller.teardown() }
        // No await: what the window would draw in this frame.
        #expect(controller.panes.count == 1)
        let pane = try #require(controller.layoutModel.screens.first?.layout.panes.first)
        #expect(controller.layoutView.contentView(for: pane) != nil)
        withExtendedLifetime((services, state)) {}
    }
}
