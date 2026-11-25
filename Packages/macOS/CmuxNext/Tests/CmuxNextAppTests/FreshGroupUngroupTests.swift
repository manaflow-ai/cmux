import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-06: "when I create new groups or whatever, I can't ungroup. When I right-click ungroup, it doesn't
/// work." A group made a moment ago shows in the sidebar at once (a pending edit under the sidebar's own id), but the
/// home session's personal store lists it only after the create's echo and the personal refetch after it. Every group
/// action looked its target up in the personal store, so the header menu's Ungroup (and Delete, Rename, the colors,
/// the fold, the moves, Pin) was refused with "That workspace group no longer exists" and the group stayed.
@MainActor @Suite(.serialized)
struct FreshGroupUngroupTests {
    /// A window on a home session with personal state and no daemon connection: a save fails on a later turn, so
    /// within the gesture's turn the new group is only the sidebar's.
    static func window() throws -> (services: AppServices, controller: WindowController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1","capabilities":["profiles-v1"]}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let keys = ["w1", "w2"]
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key)
        })
        tree.personal = PersonalState(workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        store.apply(snapshot: tree)
        let controller = try #require(services.windows.openWindow(workspaces: keys, frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        services.windows.didActivate(controller)
        try #require(services.windows.active === controller)
        controller.sidebar.resync()
        return (services, controller)
    }

    static func groups(_ bridge: SidebarBridge) -> [CmuxNextSidebar.SidebarGroup] {
        bridge.model.sections.flatMap(\.nodes).compactMap { node in
            if case let .group(group) = node { group } else { nil }
        }
    }

    /// The header menu's Ungroup on a group made in this turn: the group leaves the sidebar, its workspaces stay.
    @Test func ungroupFromTheMenuRemovesAGroupMadeAMomentAgo() throws {
        let (services, controller) = try Self.window()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let bridge = controller.sidebar
        bridge.groupFlow.newGroup(of: [CmuxNextSidebar.WorkspaceID("w1")], name: "Fresh", byUser: false)
        let fresh = try #require(Self.groups(bridge).first { $0.name == "Fresh" }, "the new group does not show: \(bridge.model.sections)")
        #expect(services.machines.local.store.personal.group(WorkspaceGroupID(rawValue: fresh.id.rawValue)) == nil,
                "the personal store already holds the group: the test no longer covers a group made a moment ago")

        // What the group header's right-click menu runs (SidebarContextMenus: the shown group's id as the target).
        let ran = services.registry.perform("workspaceGroup.ungroup", invocation: ActionInvocation(
            target: ActionTargetRef(kind: .workspaceGroup, id: fresh.id.rawValue), origin: .user))
        #expect(ran)
        #expect(Self.groups(bridge).isEmpty, "Ungroup left the new group in the sidebar: \(Self.groups(bridge).map(\.name))")
        let listed = bridge.model.sections.flatMap(\.workspaces).map(\.id.rawValue)
        #expect(listed.contains("w1"), "Ungroup lost the group's workspace: \(listed)")
        bridge.resync() // a live recompute before the daemon answered
        #expect(Self.groups(bridge).isEmpty, "a recompute drew the ungrouped group again")
    }

    /// Rename and Collapse on the same fresh group act on it too (the same target rule).
    @Test func renameAndCollapseFromTheMenuActOnAGroupMadeAMomentAgo() throws {
        let (services, controller) = try Self.window()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let bridge = controller.sidebar
        bridge.groupFlow.newGroup(of: [CmuxNextSidebar.WorkspaceID("w1")], name: "Fresh", byUser: false)
        let fresh = try #require(Self.groups(bridge).first { $0.name == "Fresh" })
        let target = ActionTargetRef(kind: .workspaceGroup, id: fresh.id.rawValue)
        _ = services.registry.perform("workspaceGroup.rename", invocation: ActionInvocation(target: target, arguments: ["name": .string("Renamed")], origin: .user))
        #expect(bridge.model.group(fresh.id)?.name == "Renamed", "Rename was refused on a group made a moment ago")
        _ = services.registry.perform("workspaceGroup.collapse", invocation: ActionInvocation(target: target, origin: .user))
        #expect(bridge.model.group(fresh.id)?.isCollapsed == true, "Collapse was refused on a group made a moment ago")
    }

    /// The target rule itself: a shown group the personal store does not hold resolves to the sidebar's group, also
    /// by the daemon's id once it made the group under its own; a group nobody shows stays refused.
    @Test func aPendingGroupResolvesByTheSidebarsIDOrTheDaemonsID() {
        let model = CmuxNextSidebar.SidebarModel(sections: [
            CmuxNextSidebar.SidebarSection(kind: .machine(CmuxNextSidebar.SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
                .group(CmuxNextSidebar.SidebarGroup(id: CmuxNextSidebar.GroupID("local-1"), name: "made here", workspaces: [])),
                .group(CmuxNextSidebar.SidebarGroup(id: CmuxNextSidebar.GroupID("grp_daemon"), name: "landed", workspaces: [])),
            ]),
        ], activeWorkspaceID: nil)
        let created = ["local-2": "grp_daemon"]
        func shown(_ target: String) -> [String]? {
            model.shownGroup(target: target, created: { created[$0] }).map { [$0.group.id.rawValue, $0.personalID, $0.group.name] }
        }
        #expect(shown("local-1") == ["local-1", "local-1", "made here"])
        #expect(shown("local-2") == ["grp_daemon", "grp_daemon", "landed"])
        #expect(shown("gone") == nil)
    }
}
