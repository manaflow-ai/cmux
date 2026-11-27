import CmuxNextActions
import CmuxNextDaemon
import CmuxNextSidebar

// The icon histories of the objects other than tabs (cx-k9go). Each finds
// its object again by id when it applies a change, so an undo after the
// object moved still reaches it and one after it closed does nothing.
extension IconHistory {
    static func workspace(_ ctx: AppActionContext) -> Self {
        inActiveWindow(ctx) { id, update in
            guard let workspace = ctx.services.workspace(id: id), let key = workspace.key else { return false }
            try WorkspaceStructureHandlers.setIcon(update, workspace: workspace, key: key, ctx)
            return true
        }
    }

    static func workspaceGroup(_ ctx: AppActionContext) -> Self {
        inActiveWindow(ctx) { id, update in
            let target = ActionInvocation(target: ActionTargetRef(kind: .workspaceGroup, id: id))
            guard let group = try? ctx.group(target) else { return false }
            try ctx.sidebar().handle(.setGroupIcon(ctx.sidebar().model.groupID(personal: group.id.rawValue), update.icon))
            return true
        }
    }

    static func space(_ ctx: AppActionContext) -> Self {
        inActiveWindow(ctx) { id, update in
            guard let room = ctx.roomStore.profile(ProfileID(rawValue: id)) else { return false }
            RoomHandlers.update(room.id, ctx) { try await $0.updateProfile($1, icon: update) }
            return true
        }
    }

    static func screen(_ ctx: AppActionContext) -> Self {
        inActiveWindow(ctx) { id, update in
            for daemon in ctx.services.machines.daemons {
                guard let screen = daemon.store.workspaces.lazy.flatMap(\.screens).first(where: { $0.id == id }) else { continue }
                guard daemon.supports(DaemonCapability.screenMetadata.rawValue) else {
                    throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapability.screenMetadata.rawValue))
                }
                ctx.services.registry.settle(ScreenCommands.setIcon(screen, update.icon, daemon: daemon), of: "screen.setIcon", ActionInvocation())
                return true
            }
            return false
        }
    }

    /// A screen group, on whichever machine owns it (`GroupOwnership`).
    static func screenGroup(_ ctx: AppActionContext) -> Self {
        inActiveWindow(ctx) { id, update in
            guard let found = GroupOwnership.screenGroup(CmuxNextDaemon.ScreenGroupID(rawValue: id), machines: ctx.services.machines) else { return false }
            guard found.daemon.supports(DaemonCapability.screenGroupIcon.rawValue) else {
                throw ActionFailure(message: found.daemon.missingCapabilityMessage(DaemonCapability.screenGroupIcon.rawValue))
            }
            ScreenGroupCommands.update(found.group.id, icon: update, daemon: found.daemon)
            return true
        }
    }

    /// A tab group, in the pane that holds it on whichever machine owns it.
    static func tabGroup(_ ctx: AppActionContext) -> Self {
        inActiveWindow(ctx) { id, update in
            let group = CmuxNextDaemon.TabGroupID(rawValue: id)
            guard let (pane, daemon) = GroupOwnership.pane(holdingTabGroup: group, machines: ctx.services.machines) else { return false }
            guard daemon.supports(DaemonCapability.tabGroupIcon.rawValue) else {
                throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapability.tabGroupIcon.rawValue))
            }
            GroupIconHandlers.send(update, toTabGroup: group, in: pane, daemon: daemon, ctx)
            return true
        }
    }

    static func browserProfile(_ ctx: AppActionContext) -> Self {
        inActiveWindow(ctx) { id, update in
            guard ctx.services.browserProfiles.record(id) != nil else { return false }
            try ctx.services.browserProfiles.setIcon(id, update.icon)
            return true
        }
    }
}

private extension FieldUpdate<String> {
    /// The icon a set or a remove leaves (nil for a remove).
    var icon: String? {
        if case .set(let icon) = self { return icon }
        return nil
    }
}
