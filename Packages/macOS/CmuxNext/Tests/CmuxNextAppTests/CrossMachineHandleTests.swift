import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Pane handles are daemon-local numbers, so a Cloud machine's pane and a
/// local pane often share one. Looking a pane's controller up by handle
/// alone returned the local window's controller for a Cloud pane, and a
/// split of that Cloud pane then started in the local tab's Mac directory
/// (the Cloud daemon refused it: "failed to spawn PTY command").
@MainActor
struct CrossMachineHandleTests {
    @Test func aCloudPaneNeverResolvesToALocalControllerWithTheSameHandle() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(ReopenClosedTabTests.identify.utf8))
        let local = services.daemon.store
        _ = local.apply(.connected(identity, generationChanged: false))
        local.apply(snapshot: try ReopenClosedTabTests.tree([ReopenClosedTabTests.tab(1, "a", cwd: "/Users/someone")]))
        let session = ReopenClosedCloudTabTests.cloudSession("vm-fedcba9876543210fedcba9876543210")
        services.machines.add(session)
        let cloud = session.daemon.store
        _ = cloud.apply(.connected(identity, generationChanged: false))
        cloud.apply(snapshot: try ReopenClosedTabTests.tree([ReopenClosedTabTests.tab(1, "c", cwd: "/home/cmux")]))

        let localPane = try #require(local.workspaces.first?.screens.first?.panes.first)
        let cloudPane = try #require(cloud.workspaces.first?.screens.first?.panes.first)
        #expect(localPane.handle == cloudPane.handle, "the fixture must give both machines the same pane handle")
        _ = services.windows.openWindow(workspaces: [try #require(local.workspaces.first).id])
        await ReopenClosedTabTests.settle { services.paneController(for: localPane) != nil }
        #expect(services.paneController(for: localPane) != nil)
        let resolved = services.paneController(for: cloudPane)
        #expect(resolved == nil, "a Cloud pane resolved to the local window's pane")
        for controller in services.windows.controllers { controller.window?.close() }
    }
}
