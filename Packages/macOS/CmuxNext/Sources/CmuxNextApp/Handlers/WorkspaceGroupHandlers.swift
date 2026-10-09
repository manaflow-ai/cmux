import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

/// Workspace groups (sidebar sections): every verb from architecture.md 7
/// (create, rename, color x9, collapse, move, ungroup, close, delete). Group
/// edits go through the active window's `SidebarBridge.handle`, the same
/// path as sidebar clicks and drags: an optimistic sidebar update, then the
/// daemon command. Groups are personal (the home session's, `profiles-v1`;
/// `workspace_group.*` on a daemon with state resources); the shared
/// workspace group commands are not used.
enum WorkspaceGroupHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        bindEdits(registry, context)
        bindMembers(registry, context)
        registry.bind("nextWorkspaceGroup", requires: DaemonCapabilities.shared.profiles, daemon: context.services.machines.local,
                      run: { _ in selectGroup(context, offset: 1) })
        registry.bind("prevWorkspaceGroup", requires: DaemonCapabilities.shared.profiles, daemon: context.services.machines.local,
                      run: { _ in selectGroup(context, offset: -1) })
    }

    private static func bindMembers(_ registry: ActionRegistry, _ context: AppActionContext) {
        let home = context.services.machines.local
        registry.bind("newWorkspaceGroup", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in
            let members = (try? context.workspace(invocation).model).map { [SidebarWorkspaceID($0.id)] } ?? []
            let name = invocation["name"]?.stringValue ?? ""
            if members.isEmpty, invocation.origin == .user, name.isEmpty { return try context.sidebar().newEmptyGroup(name: name) }
            try createGroup(named: name, members: members, byUser: invocation.origin == .user, context)
        })
        registry.bind("groupSelectedWorkspaces", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in
            var members = try context.sidebar().model.orderedSelection
            if members.isEmpty { members = [SidebarWorkspaceID(try context.workspace(invocation).model.id)] }
            try createGroup(named: "", members: members, byUser: invocation.origin == .user, context)
        })
        registry.bind("moveWorkspaceToGroup", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in
            guard invocation["group"]?.targetValue != nil else { throw ActionFailure.invalidTarget(RefusalStrings.groupRequired) }
            let group = try context.group(ActionInvocation(arguments: invocation.arguments))
            let workspace = try context.workspace(invocation).model
            try context.sidebar().handle(.move([SidebarWorkspaceID(workspace.id)], toGroup: sidebarID(group)))
        })
        registry.bind("removeWorkspaceFromGroup", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in
            guard context.usesPersonalGroups else { throw ActionFailure(message: home.personalStateUnavailableReason) }
            context.ungroupPersonal(try context.workspace(invocation).model)
        })
        registry.bind("workspaceGroup.newWorkspace", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in
            newPersonalWorkspace(in: try context.group(invocation).id, newTabPage: invocation.origin == .user, context)
        })
        registry.bind("workspaceGroup.markRead", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in try acknowledge(invocation, context) })
        registry.bind("workspaceGroup.clearNotifications", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in try acknowledge(invocation, context) })
    }

    private static func bindEdits(_ registry: ActionRegistry, _ context: AppActionContext) {
        let home = context.services.machines.local
        registry.bind("toggleFocusedWorkspaceGroupCollapsed", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in try setCollapsed(nil, invocation, context) })
        registry.bind("workspaceGroup.collapse", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in try setCollapsed(true, invocation, context) })
        registry.bind("workspaceGroup.expand", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in try setCollapsed(false, invocation, context) })
        registry.bind("workspaceGroup.setColor", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in
            guard let raw = invocation["color"]?.stringValue, let color = GroupColor(rawValue: raw) else {
                throw ActionFailure.invalidTarget(RefusalStrings.colorMustBeOneOf(GroupColor.allCases.map(\.rawValue).joined(separator: ", ")))
            }
            try edit(invocation, context) { .setGroupColor($0, color) }
        })
        for color in GroupColor.allCases {
            registry.bind(ActionID(rawValue: "workspaceGroup.color.\(color.rawValue)"), requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in
                try edit(invocation, context) { .setGroupColor($0, color) }
            })
        }
        registry.bind("workspaceGroup.rename", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in
            let group = try context.group(invocation)
            let sidebar = try context.sidebar()
            if let name = invocation["name"]?.stringValue, !name.isEmpty {
                sidebar.handle(.renameGroup(sidebarID(group), name))
            } else {
                sidebar.container.beginRename(group: sidebarID(group))
            }
        })
        registry.bind("workspaceGroup.moveUp", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in try move(invocation, by: -1, context) })
        registry.bind("workspaceGroup.moveDown", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in try move(invocation, by: 1, context) })
        registry.bind("workspaceGroup.ungroup", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in
            try WorkspaceGroupUndo.remove(invocation, context, message: WorkspaceGroupUndo.ungroupedToast)
        })
        registry.bind("workspaceGroup.closeWorkspaces", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in try edit(invocation, context) { .closeGroup($0) } })
        registry.bind("workspaceGroup.delete", requires: DaemonCapabilities.shared.profiles, daemon: home, run: { invocation in
            // RECOVERABLE-BY-DEFAULT: deleting a group keeps its workspaces
            // (Close All Workspaces in Group is the verb that closes them).
            try WorkspaceGroupUndo.remove(invocation, context, message: WorkspaceGroupUndo.deletedToast)
        })
        registry.bind("workspaceGroup.copyID", run: { invocation in context.copy(try context.group(invocation).id.rawValue) })
        registry.bind("workspaceGroup.editConfig", run: { _ in try SettingsHandlers.openCmuxConfig(context) })

        // A pinned (saved) group stays when its workspaces close.
        registry.bind("workspaceGroup.togglePin", requires: DaemonCapabilities.shared.workspaceGroupPin, daemon: home, run: { invocation in
            let group = try context.group(invocation)
            try context.sidebar().handle(.setGroupPinned(sidebarID(group), !group.pinned))
        })
        // The group icon: the shared icon string, same rule as workspace and tab icons.
        registry.bind("workspaceGroup.setIcon", requires: DaemonCapabilities.shared.workspaceGroupIcon, daemon: home, run: { invocation in
            // An icon argument (CLI, MCP, scripts) sets it; without one (palette, menu)
            // the shared icon picker opens and its pick takes the same path.
            let group = try context.group(invocation)
            let history = IconHistory.workspaceGroup(context), id = group.id.rawValue
            if let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                guard WorkspaceIconValue.isValid(icon) else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.invalidIcon) }
                return try history.change(id, from: group.icon, to: icon, origin: invocation.origin)
            }
            guard let anchor = context.services.iconPicker.anchor(group: group.id.rawValue) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen)
            }
            context.services.iconPicker.pick(current: group.icon, target: "workspaceGroup:\(id)", at: anchor) { result in
                switch result {
                case .set(let icon) where WorkspaceIconValue.isValid(icon): try? history.change(id, from: group.icon, to: icon, origin: .user)
                case .clear: try? history.change(id, from: group.icon, to: nil, origin: .user)
                case .set, .cancel: break
                }
            }
        })
        registry.bind("workspaceGroup.clearIcon", requires: DaemonCapabilities.shared.workspaceGroupIcon, daemon: home, run: { invocation in
            let group = try context.group(invocation)
            try IconHistory.workspaceGroup(context).change(group.id.rawValue, from: group.icon, to: nil, origin: invocation.origin)
        })
        registry.bind("workspaceGroup.markUnread", requires: DaemonCapabilities.shared.notificationMarkUnread, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapabilities.shared.notificationMarkUnread)
            WorkspaceUnreadMark.set(true, on: try members(invocation, context), machines: context.services.machines)
        })
    }

    /// New workspace in the window's room, then into personal group `id`.
    private static func newPersonalWorkspace(in id: WorkspaceGroupID, newTabPage: Bool, _ context: AppActionContext) {
        let windows = context.services.windows!
        let target = windows.targetWindow(preferring: windows.active?.state.id)
        let local = context.services.machines.local
        Task {
            var spawn = WorkspaceSpawn()
            spawn.opensNewTabPage = newTabPage
            // Placed into the group below, not at the new-workspace slot.
            spawn.placesBySetting = false
            guard let key = try? await windows.createWorkspace(spawn, into: target), let session = local.store.registryID else { return }
            let workspace = WorkspaceKey(rawValue: key), resource = local.store.personalStateID(session: session, key: workspace)
            local.send("set-personal-workspace") {
                try await $0.state.placePersonalWorkspace(session: session, key: workspace, resource: resource, group: .set(id))
            }
        }
    }

    private static func sidebarID(_ group: WorkspaceGroupModel) -> CmuxNextSidebar.GroupID {
        CmuxNextSidebar.GroupID(group.id.rawValue)
    }

    private static func createGroup(named name: String, members: [SidebarWorkspaceID], byUser: Bool, _ context: AppActionContext) throws {
        try context.sidebar().newGroup(of: members, name: name, byUser: byUser)
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

    private static func selectGroup(_ context: AppActionContext, offset: Int) {
        guard let window = context.activeWindow, let sidebar = try? context.sidebar(),
              !context.roomGroups.isEmpty else { return }
        let groups = context.roomGroups
        let activeGroup = sidebar.model.activeWorkspaceID.flatMap { active in
            sidebar.model.sections.flatMap(\.nodes).compactMap { node -> SidebarGroup? in
                guard case let .group(group) = node, group.workspaces.contains(where: { $0.id == active }) else { return nil }
                return group
            }.first
        }
        let activeGroupIndex = activeGroup.flatMap { current in
            groups.firstIndex { $0.id.rawValue == current.id.rawValue }
        }
        let start = activeGroupIndex ?? (offset > 0 ? -1 : groups.count)
        for step in 1...groups.count {
            let index = (start + offset * step + groups.count * 2) % groups.count
            let target = groups[index]
            if let workspace = sidebar.model.group(CmuxNextSidebar.GroupID(target.id.rawValue))?.workspaces.first(where: { $0.rowState != .placeholder }) {
                context.services.windows.show(workspaceID: workspace.id.rawValue, in: window.state)
                return
            }
        }
    }

    private static func move(_ invocation: ActionInvocation, by offset: Int, _ context: AppActionContext) throws {
        let group = try context.group(invocation)
        let ordered = context.roomGroups
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
        return context.workspaces(inPersonalGroup: id)
    }
}
