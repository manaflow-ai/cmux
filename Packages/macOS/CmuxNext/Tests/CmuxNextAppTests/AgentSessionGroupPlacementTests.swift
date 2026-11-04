import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// #27176: both `acpmux new --group` and `cmux agent open --group` choose a group
/// in the pending-placement callback. Before #26153, that callback saw rows from
/// before the create, so `canMove` rejected the unseen workspace and a duplicate
/// group was created. Exercise two placements without allowing the rows observer
/// to run between the store update and the callback.
@MainActor @Suite(.serialized)
struct AgentSessionGroupPlacementTests {
    @MainActor private final class Choices {
        var groups: [CmuxNextSidebar.GroupID?] = []
    }

    @Test func twoAgentPlacementsFindTheExistingGroupBeforeRowsRedraw() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let group = WorkspaceGroupID(rawValue: "g-lanes")
        func tree(_ keys: [String]) -> DaemonTree {
            var value = PlacementStaleRowsTests.tree(keys, personal: keys)
            value.personal?.groups = [WorkspaceGroupSnapshot(id: group, name: "lanes", profile: .defaultProfile)]
            value.personal?.workspaces[0].group = group
            return value
        }
        store.apply(snapshot: tree(["existing"]))
        let windows = services.windows
        windows.ordersWindowsIn = false
        let controller = try #require(windows.openWindow(workspaces: ["existing"]))
        defer { controller.teardown(); controller.window?.close() }
        let sidebar = controller.sidebar
        sidebar.resync()
        let drawn = sidebar.model.sections
        try #require(SidebarEdits.group(named: "lanes", accepting: SidebarWorkspaceID("existing"), in: drawn)?.rawValue == group.rawValue)

        let choices = Choices()
        let newIDs = ["lane-one", "lane-two"]
        for id in newIDs {
            NewWorkspacePlacements.expect(id, in: controller.state.id, byDefault: nil, then: { id, bridge in
                guard let bridge = bridge as? SidebarBridge else { Issue.record("placement supplied no sidebar"); return }
                choices.groups.append(SidebarEdits.group(named: "lanes", accepting: SidebarWorkspaceID(id), in: bridge.model.sections))
            }, windows: windows)
        }
        let live = ["existing"] + newIDs
        store.apply(snapshot: tree(live))
        windows.registry.apply { $0.openWindow(id: controller.state.id, workspaceIDs: live) }
        // Deliberately retain the pre-create rendering until production placement refreshes it.
        sidebar.rows.show(drawn)
        #expect(sidebar.model.sections.flatMap(\.workspaces).map(\.id.rawValue) == ["existing"])
        windows.applyPendingPlacements(live: Set(live))

        #expect(choices.groups.map { $0?.rawValue } == [group.rawValue, group.rawValue])
        #expect(windows.pendingPlacements.isEmpty)
    }
}
