import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextServer
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
        WorkspaceGroupPlaces.bind(into: registry, context: context)
        // The header menu's toggles read as the change they make on the right-clicked group.
        ActionTargetTitles.set("workspaceGroup.togglePin", in: registry) { invocation in
            (try? context.group(invocation)).map { isPinned($0, context) ? WorkspaceVerbStrings.unpinGroup : WorkspaceVerbStrings.pinGroup }
        }
        ActionTargetTitles.set("toggleFocusedWorkspaceGroupCollapsed", in: registry) { invocation in
            (try? context.group(invocation)).map { isCollapsed($0, context) ? WorkspaceVerbStrings.expandGroup : WorkspaceVerbStrings.collapseGroup }
        }
        registry.bind("nextWorkspaceGroup", requires: DaemonCapability.profiles.rawValue, daemon: context.services.machines.local,
                      run: { _ in try selectGroup(context, offset: 1) })
        registry.bind("prevWorkspaceGroup", requires: DaemonCapability.profiles.rawValue, daemon: context.services.machines.local,
                      run: { _ in try selectGroup(context, offset: -1) })
    }

    private static func bindMembers(_ registry: ActionRegistry, _ context: AppActionContext) {
        let home = context.services.machines.local
        registry.bind("newWorkspaceGroup", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            let members = (try? context.workspace(invocation).model).map { [SidebarWorkspaceID($0.id)] } ?? []
            let name = invocation["name"]?.stringValue ?? ""
            if members.isEmpty, invocation.origin == .user, name.isEmpty { return try context.sidebar().groupFlow.newEmptyGroup(name: name) }
            try createGroup(named: name, members: members, byUser: invocation.origin == .user, context)
        })
        registry.bind("groupSelectedWorkspaces", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            // The right-clicked row's selection, or the row alone: a right-click no longer selects its row (Leo
            // 2026-10-21), so a row outside the selection must not group the selection.
            let members = try WindowMembershipHandlers.workspaces(invocation, context).map(SidebarWorkspaceID.init)
            try createGroup(named: "", members: members, byUser: invocation.origin == .user, context)
        })
        registry.bind("moveWorkspaceToGroup", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            guard invocation["group"]?.targetValue != nil else { throw ActionFailure.invalidTarget(RefusalStrings.groupRequired) }
            let group = try context.group(ActionInvocation(arguments: invocation.arguments))
            let workspace = try context.workspace(invocation).model
            // The right-clicked row, or the multi-selection it belongs to.
            let sidebar = try WorkspaceVerbHandlers.sidebar(showing: workspace, context)
            let ids = try WindowMembershipHandlers.workspaces(invocation, context).map(SidebarWorkspaceID.init)
            // The drag's rule (SidebarEdits.canMove): a group holds one machine row's workspaces.
            guard SidebarEdits.canMove(ids, toGroup: sidebar.model.groupID(personal: group.id.rawValue), in: sidebar.model.sections) else {
                throw ActionFailure(message: RefusalStrings.groupOnAnotherMachine)
            }
            sidebar.handle(.move(ids, toGroup: sidebar.model.groupID(personal: group.id.rawValue)))
        })
        registry.bind("removeWorkspaceFromGroup", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            guard context.usesPersonalGroups else { throw ActionFailure(message: home.personalStateUnavailableReason) }
            // Every grouped row of the selection the right-clicked row belongs to.
            let grouped = try WindowMembershipHandlers.workspaces(invocation, context).compactMap(context.services.workspace(id:))
                .filter { (try? WorkspaceVerbHandlers.group(of: $0, context)) != nil }
            removeFromGroups(grouped, context)
        })
        ActionTargetVisibility.hide("removeWorkspaceFromGroup", in: registry) { (try? context.workspace($0).model).map { (try? WorkspaceVerbHandlers.group(of: $0, context)) == nil } ?? false }
        ActionTargetVisibility.hide("groupSelectedWorkspaces", in: registry) { ((try? WindowMembershipHandlers.workspaces($0, context).count) ?? 0) < 2 }
        registry.bind("workspaceGroup.newWorkspace", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            try newPersonalWorkspace(in: context.group(invocation).id, newTabPage: invocation.origin == .user, context)
        })
        registry.bind("workspaceGroup.newSubgroup", run: { invocation in
            // A document group (a nested one too) may have no personal-store row: the target's id is enough.
            let explicit = [invocation.target, invocation["group"]?.targetValue].compactMap { $0 }.first { $0.kind == .workspaceGroup }
            // A personal group's id or exact name (`cmux workspace group create --parent Fleet`) names its document item.
            let parent = try explicit.map { ref in (try? context.sidebar())?.model.groupID(personal: context.services.machines.local.store.personal.groups.first { $0.id.rawValue == ref.id || $0.name == ref.id }?.id.rawValue ?? ref.id) ?? CmuxNextSidebar.GroupID(ref.id) } ?? sidebarID(context.group(invocation), context)
            let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try newSubgroup(in: parent, name: name, byUser: invocation.origin == .user, context)
        })
        registry.bind("workspaceGroup.markRead", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in try acknowledge(invocation, context) })
        registry.bind("workspaceGroup.clearNotifications", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in try acknowledge(invocation, context) })
    }

    private static func bindEdits(_ registry: ActionRegistry, _ context: AppActionContext) {
        let home = context.services.machines.local
        registry.bind("toggleFocusedWorkspaceGroupCollapsed", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in try setCollapsed(nil, invocation, context) })
        registry.bind("workspaceGroup.collapse", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in try setCollapsed(true, invocation, context) })
        registry.bind("workspaceGroup.expand", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in try setCollapsed(false, invocation, context) })
        registry.bind("workspaceGroup.setColor", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            // A palette token or a custom `#RRGGBB` (cx-25az), the group editor's two kinds.
            guard let raw = invocation["color"]?.stringValue, let color = GroupTint(wire: raw) else {
                throw ActionFailure.invalidTarget(RefusalStrings.colorMustBeOneOf((GroupColor.allCases.map(\.rawValue) + ["#RRGGBB"]).joined(separator: ", ")))
            }
            try edit(invocation, context) { .setGroupColor($0, color) }
        })
        // No color (`none`): the header draws no dot, band or line (Lawrence 2026-10-22).
        registry.bind("workspaceGroup.clearColor", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            try edit(invocation, context) { .setGroupColor($0, GroupTint.none) }
        })
        for color in GroupColor.allCases {
            registry.bind(ActionID(rawValue: "workspaceGroup.color.\(color.rawValue)"), requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
                try edit(invocation, context) { .setGroupColor($0, .palette(color)) }
            })
        }
        registry.bind("workspaceGroup.rename", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            let group = try context.group(invocation)
            let sidebar = try context.sidebar()
            if let name = invocation["name"]?.stringValue, !name.isEmpty {
                sidebar.handle(.renameGroup(sidebarID(group, context), name))
            } else {
                sidebar.container.beginRename(group: sidebarID(group, context))
            }
        })
        // Top, Up, Down, Bottom among the section's rows (u2418), one undoable sidebar move each.
        let moves: [(ActionID, SidebarGroupMove)] = [("workspaceGroup.moveToTop", .top), ("workspaceGroup.moveUp", .up),
                                                     ("workspaceGroup.moveDown", .down), ("workspaceGroup.moveToBottom", .bottom)]
        for (id, direction) in moves {
            registry.bind(id, requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in try move(invocation, direction, context) })
            // At the edge of its section the row is disabled with the reason (the first group's Move Up).
            context.setTargetReason(id) { invocation in
                guard let group = try? sidebarID(context.group(invocation), context), let sidebar = try? context.sidebar(),
                      sidebar.model.group(group) != nil, SidebarEdits.groupIndex(group, direction, in: sidebar.model.sections) == nil else { return nil }
                return edgeReason(direction)
            }
        }
        registry.bind("workspaceGroup.collapseOthers", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            let group = sidebarID(try context.group(invocation), context)
            let sidebar = try context.sidebar()
            for id in SidebarEdits.groupsToggledByCollapsingOthers(keeping: group, in: sidebar.model.sections) {
                sidebar.handle(.toggleCollapse(.group(id)))
            }
        })
        registry.bind("workspaceGroup.ungroup", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            try WorkspaceGroupUndo.remove(invocation, context, message: WorkspaceGroupUndo.ungroupedToast, toast: false)
        })
        registry.bind("workspaceGroup.closeWorkspaces", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            try WorkspaceGroupClose.close(invocation, context)
        })
        registry.bind("workspaceGroup.delete", requires: DaemonCapability.profiles.rawValue, daemon: home, run: { invocation in
            // RECOVERABLE-BY-DEFAULT: deleting a group keeps its workspaces
            // (Close Workspaces in Group is the verb that closes them).
            try WorkspaceGroupUndo.remove(invocation, context, message: WorkspaceGroupUndo.deletedToast)
        })
        registry.bind("workspaceGroup.copyID", run: { invocation in context.copy(try context.group(invocation).id.rawValue) })
        registry.bind("workspaceGroup.editConfig", run: { invocation in try WorkspaceGroupConfigEditor(context: context).open(invocation) })

        // A pinned (saved) group stays when its workspaces close.
        registry.bind("workspaceGroup.togglePin", requires: DaemonCapability.workspaceGroupPin.rawValue, daemon: home, run: { invocation in
            // On the sidebar document a pinned group is one in Pinned, as shown (pending changes included).
            // A `pinned` argument (CLI, MCP, scripts) sets that state instead of toggling.
            let group = try context.group(invocation), id = sidebarID(group, context)
            let pinned = invocation["pinned"]?.boolValue ?? !(SidebarDocStore.current?.showsPinned(group: id.rawValue) ?? isPinned(group, context))
            try context.sidebar().handle(.setGroupPinned(id, pinned))
        })
        // The group icon: the shared icon string, same rule as workspace and tab icons.
        registry.bind("workspaceGroup.setIcon", requires: DaemonCapability.workspaceGroupIcon.rawValue, daemon: home, run: { invocation in
            // An icon argument (CLI, MCP, scripts) sets it; without one (palette, menu)
            // the shared icon picker opens and its pick takes the same path.
            let group = try context.group(invocation)
            let history = IconHistory.workspaceGroup(context), id = group.id.rawValue
            if let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty {
                guard WorkspaceIconValue.isValid(icon, assets: true) else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.invalidIcon) }
                return try history.change(id, from: group.icon, to: icon, origin: invocation.origin)
            }
            guard let anchor = context.services.iconPicker.anchor(group: group.id.rawValue) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen)
            }
            // A stored image or SVG goes to the home daemon, which keeps the group (cx-qno.11.1).
            context.services.iconPicker.pick(current: group.icon, target: "workspaceGroup:\(id)", at: anchor,
                                             assets: IconAssetStore.owner(home)) { result in
                switch result {
                case .set(let icon) where WorkspaceIconValue.isValid(icon, assets: true): try? history.change(id, from: group.icon, to: icon, origin: .user)
                case .clear: try? history.change(id, from: group.icon, to: nil, origin: .user)
                case .set, .cancel: break
                }
            }
        })
        registry.bind("workspaceGroup.clearIcon", requires: DaemonCapability.workspaceGroupIcon.rawValue, daemon: home, run: { invocation in
            let group = try context.group(invocation)
            try IconHistory.workspaceGroup(context).change(group.id.rawValue, from: group.icon, to: nil, origin: invocation.origin)
        })
        registry.bind("workspaceGroup.markUnread", requires: DaemonCapability.notificationMarkUnread.rawValue, daemon: context.services.activeDaemon, run: { invocation in
            try context.require(DaemonCapability.notificationMarkUnread.rawValue)
            WorkspaceUnreadMark.set(true, on: try members(invocation, context), machines: context.services.machines)
        })
    }

    /// New workspace in the window's room, made on the machine the group's workspaces run on
    /// (`GroupSpawnHost`: a group in a remote host's section stays on that host), then into
    /// personal group `id`. A remote host that is not connected refuses instead of making it here.
    private static func newPersonalWorkspace(in id: WorkspaceGroupID, newTabPage: Bool, _ context: AppActionContext) throws {
        let windows = context.services.windows
        let target = windows.targetWindow(preferring: windows.active?.state.id)
        let machines = context.services.machines, local = machines.local
        let homes = context.workspaces(inPersonalGroup: id).compactMap { member in
            machines.daemons.first { daemon in daemon.store.workspaces.contains { $0.id == member.id } }
        }
        let daemon = GroupSpawnHost(memberHomes: homes, local: local).host
        guard daemon === local || daemon.connection != nil else {
            throw ActionFailure.invalidTarget(WorkspaceVerbStrings.machineNotConnected)
        }
        var spawn = WorkspaceSpawn()
        spawn.opensNewTabPage = newTabPage
        // Only the group places it: never the new-workspace setting first (a slot in another group).
        spawn.placesBySetting = false
        // The group's slot, the path a double-click in the group takes: the row shows in the group from the press
        // and is placed once the daemon lists it. Setting the group right after the create raced that listing:
        // without the workspace's public id the place went out as the raw command, and it stayed outside the group.
        let slot = windows.controller(for: target).flatMap { controller in
            shownGroupID(id, in: controller.sidebar.model).map { groupSlot($0, in: controller.sidebar.model, window: target, context) }
        }
        spawn.slot = slot
        spawn.onListed = { key, bridge in
            // A slot that did not resolve where it is listed (the group is in another room) placed nothing.
            let sections = SidebarRowSection.withoutPlaceholders(bridge.sections)
            let section = SectionID.machine(MachineID(daemon.machineID))
            guard slot?.position(moving: [key], section: section, in: sections) == nil, let session = daemon.store.registryID else { return }
            // The group lives in the home session's personal state, whichever machine runs the workspace.
            let workspace = WorkspaceKey(rawValue: key), resource = local.store.personalStateID(session: session, key: workspace)
            local.send("set-personal-workspace") {
                try await $0.state.placePersonalWorkspace(session: session, key: workspace, resource: resource, group: .set(id))
            }
        }
        // The CLI answers after the create, and a palette or menu run shows its failure.
        context.report {
            do {
                _ = try await windows.createWorkspace(spawn, on: daemon, into: target)
                return nil
            } catch {
                return ActionWorkFailure("new workspace", error)
            }
        }
    }

    /// Where New Workspace in Group puts the new workspace in group `shown`. cmux.json
    /// `workspaceGroups` (by the group's anchor folder), when it names a placement: after its first
    /// workspace (`top`, and `afterCurrent`, whose reference is the anchor for the header's + and the
    /// CLI), else last. Else `workspaces.newPlacement`, as for every new workspace made in a group
    /// (`NewWorkspaceDefaultSlot.slot(inGroup:members:)`): the group's top under the default `top`.
    private static func groupSlot(_ shown: CmuxNextSidebar.GroupID, in model: SidebarModel, window: String?,
                                  _ context: AppActionContext) -> WorkspaceSlot {
        let members = model.group(shown)?.workspaces.map(\.id.rawValue) ?? []
        let config = context.services.settings?.snapshot.workspaceGroups ?? WorkspaceGroupConfig()
        let anchor = WorkspaceGroupConfigLook.anchorDirectory(of: members.compactMap { context.services.machines.workspace(id: $0)?.0 })
        switch config.configuredPlacement(for: anchor) {
        case .top?, .afterCurrent?:
            return members.first.map(WorkspaceSlot.below) ?? .endOfGroup(shown)
        case .end?:
            return .endOfGroup(shown)
        case nil:
            return NewWorkspacePlacements.rule(for: window, in: context.services.windows).slot(inGroup: shown, members: members)
        }
    }

    /// The id `model` lists personal group `id` under (`SidebarModel.groupID(personal:)`), nil when it lists none.
    private static func shownGroupID(_ id: WorkspaceGroupID, in model: SidebarModel) -> CmuxNextSidebar.GroupID? {
        let shown = model.groupID(personal: id.rawValue)
        return model.group(shown) != nil ? shown : nil
    }

    /// A new group inside `parent` on the sidebar document (remote-groups-DESIGN.md slice 3), with the
    /// next palette color; a person's new subgroup opens its name editor, as New Group does.
    private static func newSubgroup(in parent: CmuxNextSidebar.GroupID, name: String, byUser: Bool, _ context: AppActionContext) throws {
        guard let store = SidebarDocStore.current, SidebarDocWiring.isActive else {
            throw ActionFailure.invalidTarget(WorkspaceVerbStrings.subgroupNeedsDocument)
        }
        let id = CmuxNextSidebar.GroupID.make()
        let used = Set(context.services.machines.local.store.personal.groups.compactMap(\.color))
        let plan = SidebarDocSubgroupPlan(parent: parent, id: id, name: name, color: GroupColor.automatic(used: used) ?? .grey,
                                          records: store.records)
        guard let ops = plan.ops else {
            throw ActionFailure.invalidTarget(plan.refusal == .tooDeep ? WorkspaceVerbStrings.subgroupTooDeep : RefusalStrings.groupRequired)
        }
        do {
            try store.sendChecked(ops: ops, title: SidebarDocStore.moveTitle)
        } catch {
            throw ActionFailure.invalidTarget(error.message)
        }
        // A person names it in the editor; a name given by the CLI or MCP is already set.
        if byUser, name.isEmpty { try context.sidebar().groupFlow.editGroup(WorkspaceGroupID(rawValue: id.rawValue)) }
    }

    /// The id the active sidebar shows `group` under (its sidebar document item on sidebar-v2).
    private static func sidebarID(_ group: WorkspaceGroupModel, _ context: AppActionContext) -> CmuxNextSidebar.GroupID {
        (try? context.sidebar())?.model.groupID(personal: group.id.rawValue) ?? CmuxNextSidebar.GroupID(group.id.rawValue)
    }

    /// The fold the sidebar shows (the sidebar document keeps its own), else the personal group's.
    private static func isCollapsed(_ group: WorkspaceGroupModel, _ context: AppActionContext) -> Bool {
        (try? context.sidebar().model.group(sidebarID(group, context))?.isCollapsed) ?? group.collapsed
    }

    /// Whether the group reads as pinned where the person sees it: in the Pinned band on the sidebar
    /// document, else the personal group's saved flag. Pin/Unpin toggles from this.
    private static func isPinned(_ group: WorkspaceGroupModel, _ context: AppActionContext) -> Bool {
        (try? context.sidebar().model.group(sidebarID(group, context))?.isPinned) ?? group.pinned
    }

    private static func createGroup(named name: String, members: [SidebarWorkspaceID], byUser: Bool, _ context: AppActionContext) throws {
        try context.sidebar().groupFlow.newGroup(of: members, name: name, byUser: byUser)
    }

    /// Takes `workspaces` out of their groups as one move of their rows per section (#26382): they leave in this turn,
    /// the way a drag out of a group does, and the same path saves them (and brings them back, saying why, when the
    /// save fails). They go, in tree order, after the loose rows when the sidebar lists those first (before its first
    /// unpinned group), else just below the first one's group. A workspace no sidebar shows in a machine section's
    /// group takes the personal write alone (a row in Pinned would be pinned by a move there).
    private static func removeFromGroups(_ workspaces: [WorkspaceModel], _ context: AppActionContext) {
        var moves: [(sidebar: SidebarBridge, section: Int, ids: [SidebarWorkspaceID])] = []
        for workspace in workspaces {
            let id = SidebarWorkspaceID(workspace.id)
            guard let sidebar = try? WorkspaceVerbHandlers.sidebar(showing: workspace, context),
                  let at = SidebarEdits.locate(id, in: sidebar.model.sections), at.child != nil,
                  sidebar.model.sections.dropFirst(at.section).first?.id != .pinned else {
                context.ungroupPersonal(workspace)
                continue
            }
            if let index = moves.firstIndex(where: { $0.sidebar === sidebar && $0.section == at.section }) {
                moves[index].ids.append(id)
            } else {
                moves.append((sidebar, at.section, [id]))
            }
        }
        for (sidebar, s, ids) in moves {
            let sections = sidebar.model.sections
            guard let section = sections.dropFirst(s).first, let first = SidebarEdits.treeOrder(ids, in: sections).first,
                  let at = SidebarEdits.locate(first, in: sections) else { continue }
            let firstUnpinnedGroup = section.nodes.firstIndex { if case let .group(group) = $0 { !group.isPinned } else { false } }
            let index = sidebar.model.ungroupedFirst ? firstUnpinnedGroup ?? section.nodes.count : at.node + 1
            sidebar.handle(.reorder(ids, to: DropPosition(section: section.id, index: index)))
        }
    }

    /// Sends a sidebar intent for the targeted group.
    private static func edit(_ invocation: ActionInvocation, _ context: AppActionContext,
                             _ intent: (CmuxNextSidebar.GroupID) -> SidebarIntent) throws {
        let group = try context.group(invocation)
        try context.sidebar().handle(intent(sidebarID(group, context)))
    }

    /// nil toggles.
    private static func setCollapsed(_ collapsed: Bool?, _ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let group = try context.group(invocation)
        guard collapsed == nil || collapsed != isCollapsed(group, context) else { return }
        try context.sidebar().handle(.toggleCollapse(.group(sidebarID(group, context))))
    }

    /// Shows the first workspace of the next (or previous) group of the room. A navigation with
    /// nowhere to go (R136: no group, or no group with a workspace) is refused quietly.
    private static func selectGroup(_ context: AppActionContext, offset: Int) throws {
        guard let window = context.activeWindow else { throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen) }
        let sidebar = try context.sidebar()
        let groups = context.roomGroups
        guard !groups.isEmpty else { throw ActionFailure.noTarget(RefusalStrings.noWorkspaceGroups) }
        // By personal id: on the sidebar document the group lists as its item (`itm_g_<id>`).
        let activeGroupIndex = sidebar.model.activeGroupPersonalID.flatMap { current in groups.firstIndex { $0.id.rawValue == current } }
        let start = activeGroupIndex ?? (offset > 0 ? -1 : groups.count)
        for step in 1...groups.count {
            let index = (start + offset * step + groups.count * 2) % groups.count
            let target = groups[index]
            if let workspace = sidebar.model.group(sidebar.model.groupID(personal: target.id.rawValue)).flatMap(WorkspaceGroupFocus.firstWorkspace) {
                context.services.windows.show(workspaceID: workspace.rawValue, in: window.state)
                return
            }
        }
        throw ActionFailure.noTarget(RefusalStrings.noWorkspaceGroupToGoTo)
    }

    /// Moves the targeted group among its section's rows. `reorderGroup` counts every row of the
    /// section (loose workspaces too), not the group's place among the room's groups.
    private static func move(_ invocation: ActionInvocation, _ direction: SidebarGroupMove, _ context: AppActionContext) throws {
        let group = sidebarID(try context.group(invocation), context)
        let sidebar = try context.sidebar()
        guard let index = SidebarEdits.groupIndex(group, direction, in: sidebar.model.sections) else {
            throw ActionFailure.invalidTarget(sidebar.model.group(group) == nil ? RefusalStrings.noWorkspaceGroup(group.rawValue) : edgeReason(direction))
        }
        sidebar.handle(.reorderGroup(group, index: index))
    }

    /// Why a group move toward `direction` cannot go further.
    private static func edgeReason(_ direction: SidebarGroupMove) -> String {
        switch direction {
        case .top, .up: RefusalStrings.groupAlreadyAtTop
        case .down, .bottom: RefusalStrings.groupAlreadyAtBottom
        }
    }

    private static func acknowledge(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        try WorkspaceMetadataHandlers.acknowledge(try members(invocation, context), context)
    }

    /// The workspaces of the targeted group.
    static func members(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> [WorkspaceModel] {
        let id = try context.group(invocation).id
        return context.workspaces(inPersonalGroup: id)
    }
}
