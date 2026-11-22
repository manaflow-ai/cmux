import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// Leo, 2026-11-01: "a lot of these asks or whatever when you guys create them it looks really odd when they pop
/// up into some existing group on the sidebar as a workspace and then go to wherever they're supposed to go to".
/// A session an agent opens with `group` (`acpmux new --group`, `cmux agent open --group`) is placed in that group
/// and nowhere else: never first at Cmd-N's slot in the window's current group, then moved across to its own.
@MainActor @Suite(.serialized)
struct AgentSessionGroupDirectPlacementTests {
    @MainActor private final class Seen {
        var groupBeforeJoin: String??
    }

    @Test func aNamedGroupIsTheNewRowsOnlyPlace() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let current = WorkspaceGroupID(rawValue: "g-current"), lanes = WorkspaceGroupID(rawValue: "g-lanes")
        // Sorted keys: "a-current" (shown, in "current"), "b-lane" (in "lanes"), then the new "c-new".
        func tree(_ keys: [String]) -> DaemonTree {
            var value = PlacementStaleRowsTests.tree(keys, personal: keys)
            value.personal?.groups = [WorkspaceGroupSnapshot(id: current, name: "current", profile: .defaultProfile),
                                      WorkspaceGroupSnapshot(id: lanes, name: "lanes", profile: .defaultProfile)]
            value.personal?.workspaces[0].group = current
            value.personal?.workspaces[1].group = lanes
            return value
        }
        let keys = ["a-current", "b-lane"]
        store.apply(snapshot: tree(keys))
        let windows = services.windows
        windows.ordersWindowsIn = false
        let controller = try #require(windows.openWindow(workspaces: keys))
        defer { controller.teardown(); controller.window?.close() }
        let sidebar = controller.sidebar
        sidebar.resync()
        try #require(windows.states[controller.state.id]?.workspaceID == "a-current")

        AgentSessionWorkspace.expectPlacement("c-new", group: "lanes", top: false, parent: nil, windows: windows)
        // Where the row stands when the group join runs: every placement before it is a step a person sees.
        let pending = try #require(windows.pendingPlacements["c-new"])
        let join = try #require(pending.then)
        let seen = Seen()
        windows.pendingPlacements["c-new"]?.then = { id, bridge in
            if let bridge = bridge as? SidebarBridge {
                seen.groupBeforeJoin = .some(Self.group(of: id, in: bridge.model.sections))
            }
            join(id, bridge)
        }
        let live = keys + ["c-new"]
        store.apply(snapshot: tree(live))
        windows.registry.apply { $0.openWindow(id: controller.state.id, workspaceIDs: live) }
        windows.applyPendingPlacements(live: Set(live))

        #expect(seen.groupBeforeJoin != nil, "the group join ran")
        #expect(seen.groupBeforeJoin != .some(current.rawValue), "the new row stood in the window's current group before joining its own")
        #expect(Self.group(of: "c-new", in: sidebar.model.sections) == lanes.rawValue)
        #expect(windows.pendingPlacements.isEmpty)
    }

    /// Without `group`, an agent's open keeps Cmd-N's placement (#29889's parent group, else the setting).
    @Test func withoutAGroupTheSettingStillPlacesIt() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let windows = services.windows
        AgentSessionWorkspace.expectPlacement("c-new", group: nil, top: false, parent: nil, windows: windows)
        #expect(windows.pendingPlacements["c-new"]?.byDefault != nil)
        #expect(windows.pendingPlacements["c-new"]?.then == nil)
    }

    private static func group(of id: String, in sections: [CmuxNextSidebar.SidebarSection]) -> String? {
        for section in sections {
            for node in section.nodes {
                if case let .group(group) = node, group.workspaces.contains(where: { $0.id.rawValue == id }) { return group.id.rawValue }
            }
        }
        return nil
    }
}
