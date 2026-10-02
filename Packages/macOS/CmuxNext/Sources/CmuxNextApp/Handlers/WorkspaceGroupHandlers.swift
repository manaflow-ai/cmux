import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

/// Workspace groups (sidebar sections): every verb from architecture.md 7
/// (create, rename, color x9, collapse, move, ungroup, close, delete). Group
/// edits go through the active window's `SidebarBridge.handle`, the same
/// path as sidebar clicks and drags: an optimistic sidebar update, then the
/// daemon command. Requires `workspace-groups-v1`.
enum WorkspaceGroupHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("newWorkspaceGroup", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapabilities.shared.workspaceGroups)
            let members = (try? context.workspace(invocation).model).map { [SidebarWorkspaceID($0.id)] } ?? []
            try createGroup(named: invocation["name"]?.stringValue ?? "", members: members, context)
        })
        registry.bind("groupSelectedWorkspaces", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapabilities.shared.workspaceGroups)
            var members = try context.sidebar().model.orderedSelection
            if members.isEmpty { members = [SidebarWorkspaceID(try context.workspace(invocation).model.id)] }
            try createGroup(named: "", members: members, context)
        })
        registry.bind("moveWorkspaceToGroup", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapabilities.shared.workspaceGroups)
            guard invocation["group"]?.targetValue != nil else { throw ActionFailure.invalidTarget(RefusalStrings.groupRequired) }
            let group = try context.group(ActionInvocation(arguments: invocation.arguments))
            let workspace = try context.workspace(invocation).model
            try context.sidebar().handle(.move([SidebarWorkspaceID(workspace.id)], toGroup: sidebarID(group)))
        })
        registry.bind("removeWorkspaceFromGroup", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in
            if context.usesPersonalGroups { return context.ungroupPersonal(try context.workspace(invocation).model) }
            try context.require(DaemonCapabilities.shared.workspaceGroups)
            let key = try context.workspace(invocation).key
            let daemon = context.services.activeDaemon
            Task {
                await daemon.intend("move-workspace-to-group", .setWorkspaceGroup(key: key, group: nil)) { connection in
                    _ = try await connection.moveWorkspace(key, toGroup: nil)
                }
            }
        })
        registry.bind("toggleFocusedWorkspaceGroupCollapsed", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in try setCollapsed(nil, invocation, context) })
        registry.bind("workspaceGroup.collapse", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in try setCollapsed(true, invocation, context) })
        registry.bind("workspaceGroup.expand", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in try setCollapsed(false, invocation, context) })
        registry.bind("workspaceGroup.setColor", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in
            guard let raw = invocation["color"]?.stringValue, let color = GroupColor(rawValue: raw) else {
                throw ActionFailure.invalidTarget(RefusalStrings.colorMustBeOneOf(GroupColor.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            try edit(invocation, context) { .setGroupColor($0, color) }
        })
        for color in GroupColor.allCases {
            registry.bind(ActionID(rawValue: "workspaceGroup.color.\(color.rawValue)"), requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in
                try edit(invocation, context) { .setGroupColor($0, color) }
            })
        }
        registry.bind("workspaceGroup.rename", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in
            let group = try context.group(invocation)
            let sidebar = try context.sidebar()
            if let name = invocation["name"]?.stringValue, !name.isEmpty {
                sidebar.handle(.renameGroup(sidebarID(group), name))
            } else {
                sidebar.container.beginRename(group: sidebarID(group))
            }
        })
        registry.bind("workspaceGroup.moveUp", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in try move(invocation, by: -1, context) })
        registry.bind("workspaceGroup.moveDown", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in try move(invocation, by: 1, context) })
        registry.bind("workspaceGroup.ungroup", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in try edit(invocation, context) { .ungroup($0) } })
        registry.bind("workspaceGroup.closeWorkspaces", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in try edit(invocation, context) { .closeGroup($0) } })
        registry.bind("workspaceGroup.delete", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in
            // Destructive sibling of ungroup (old app semantics): closes the
            // members, then removes the group.
            let group = try context.group(invocation)
            try context.sidebar().handle(.closeGroup(sidebarID(group)))
            let id = group.id
            if context.usesPersonalGroups {
                context.services.machines.local.send("delete-personal-group") { try await $0.deletePersonalGroup(id) }
            } else {
                context.services.activeDaemon.send("delete-workspace-group") { try await $0.deleteGroup(id) }
            }
        })
        registry.bind("workspaceGroup.newWorkspace", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in
            let id = try context.group(invocation).id
            if context.usesPersonalGroups { return newPersonalWorkspace(in: id, context) }
            WorkspaceHandlers.createAndShow(context) { connection, terminal in
                _ = try await connection.moveWorkspace(terminal.key, toGroup: id)
            }
        })
        registry.bind("workspaceGroup.markRead", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in try acknowledge(invocation, context) })
        registry.bind("workspaceGroup.clearNotifications", requires: DaemonCapabilities.shared.workspaceGroups, daemon: context.services.activeDaemon, run: { invocation in try acknowledge(invocation, context) })
        registry.bind("workspaceGroup.editConfig", run: { _ in try SettingsHandlers.openCmuxConfig(context) })

        registry.bindUnavailable(["workspaceGroup.togglePin"], ActionFailure.needsDaemonCapability("workspace-group-pin-v1"))
        registry.bind("workspaceGroup.markUnread", requires: DaemonCapabilities.shared.notificationMarkUnread, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapabilities.shared.notificationMarkUnread)
            WorkspaceUnreadMark.set(true, on: try members(invocation, context), machines: context.services.machines)
        })
    }

    /// New workspace in the window's room, then into personal group `id`.
    private static func newPersonalWorkspace(in id: WorkspaceGroupID, _ context: AppActionContext) {
        let windows = context.services.windows!
        let target = windows.targetWindow(preferring: windows.active?.state.id)
        let local = context.services.machines.local
        Task {
            guard let key = try? await windows.createWorkspace(WorkspaceSpawn(), into: target), let session = local.store.registryID else { return }
            local.send("set-personal-workspace") {
                try await $0.setPersonalWorkspace(SetPersonalWorkspaceRequest(sessionID: session, workspaceKey: WorkspaceKey(rawValue: key),
                                                                              group: .set(id)))
            }
        }
    }

    private static func sidebarID(_ group: WorkspaceGroupModel) -> CmuxNextSidebar.GroupID {
        CmuxNextSidebar.GroupID(group.id.rawValue)
    }

    private static func createGroup(named name: String, members: [SidebarWorkspaceID], _ context: AppActionContext) throws {
        try context.sidebar().handle(.createGroup(.make(), name: name, color: .grey, workspaces: members))
    }

    /// Sends a sidebar intent for the targeted group.
    private static func edit(_ invocation: ActionInvocation, _ context: AppActionContext,
                             _ intent: (CmuxNextSidebar.GroupID) -> SidebarIntent) throws {
        let group = try context.group(invocation)
        try context.sidebar().handle(intent(sidebarID(group)))
    }

    /// nil toggles.
    private static func setCollapsed(_ collapsed: Bool?, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let group = try context.group(invocation)
        guard collapsed == nil || collapsed != group.collapsed else { return }
        try context.sidebar().handle(.toggleCollapse(.group(sidebarID(group))))
    }

    private static func move(_ invocation: ActionInvocation, by offset: Int, _ context: AppActionContext) throws {
        let group = try context.group(invocation)
        let ordered = context.usesPersonalGroups ? context.roomGroups : context.store.groups.sorted { $0.index < $1.index }
        guard let index = ordered.firstIndex(where: { $0 === group }) else { return }
        let target = min(max(index + offset, 0), ordered.count - 1)
        guard target != index else { return }
        try context.sidebar().handle(.reorderGroup(sidebarID(group), index: target))
    }

    private static func acknowledge(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        try WorkspaceMetadataHandlers.acknowledge(try members(invocation, context), context)
    }

    /// The workspaces of the targeted group.
    private static func members(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> [WorkspaceModel] {
        let id = try context.group(invocation).id
        return context.usesPersonalGroups ? context.workspaces(inPersonalGroup: id) : context.store.workspaces.filter { $0.group == id }
    }
}
