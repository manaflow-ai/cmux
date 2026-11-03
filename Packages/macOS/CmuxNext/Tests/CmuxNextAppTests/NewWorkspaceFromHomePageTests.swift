import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/32731: Cmd-N from Home made the new workspace at the top, then moved it
/// next to the workspace selected before Home. The Home page parks that workspace and keeps `state.workspaceID`, but
/// the window shows no workspace, so `workspaces.newPlacement` has no current one: the new row keeps the daemon's
/// first slot and no second move follows.
@MainActor @Suite(.serialized)
struct NewWorkspaceFromHomePageTests {
    @Test func cmdNFromHomeKeepsTheNewRowWhereItWasMade() throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let group = WorkspaceGroupID(rawValue: "g-last")
        // "a-last" (the workspace shown before Home, in group "last"), "b-loose", then the new "c-new".
        func tree(_ keys: [String]) -> DaemonTree {
            var value = PlacementStaleRowsTests.tree(keys, personal: keys)
            value.personal?.groups = [WorkspaceGroupSnapshot(id: group, name: "last", profile: .defaultProfile)]
            value.personal?.workspaces[0].group = group
            return value
        }
        let keys = ["a-last", "b-loose"]
        store.apply(snapshot: tree(keys))
        let windows = services.windows
        windows.ordersWindowsIn = false
        let controller = try #require(windows.openWindow(workspaces: keys))
        defer { controller.teardown(); controller.window?.close() }
        let sidebar = controller.sidebar
        sidebar.resync()
        let window = controller.state.id
        try #require(windows.states[window]?.workspaceID == "a-last")

        // On the workspace itself, Cmd-N's rule anchors to it (the new row joins its group).
        #expect(NewWorkspacePlacements.rule(for: window, in: windows).current == "a-last")

        // Home shows: the last workspace stays parked under the page.
        controller.state.page = .home
        let rule = NewWorkspacePlacements.rule(for: window, in: windows)
        #expect(rule.current == nil, "the workspace parked under Home is not the current one")

        NewWorkspacePlacements.expect("c-new", in: window, byDefault: rule, windows: windows)
        let live = keys + ["c-new"]
        store.apply(snapshot: tree(live))
        windows.registry.apply { $0.openWindow(id: window, workspaceIDs: live) }
        windows.applyPendingPlacements(live: Set(live))

        #expect(Self.group(of: "c-new", in: sidebar.model.sections) == nil, "the new row moved into the parked workspace's group")
        #expect(windows.pendingPlacements.isEmpty)
    }

    private static func group(of id: String, in sections: [CmuxNextSidebar.SidebarSection]) -> String? {
        for section in sections {
            for node in section.nodes {
                if case let .group(value) = node, value.workspaces.contains(where: { $0.id.rawValue == id }) { return value.id.rawValue }
            }
        }
        return nil
    }
}
