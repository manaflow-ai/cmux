import CmuxNextActions
import CmuxNextDaemon

/// Remove Icon only where there is an icon to remove (cx-k9go): every
/// object whose icon can be set (workspace, workspace group, space, tab,
/// screen, screen group, tab group, browser profile) leaves "Remove Icon"
/// out of its right-click menu while it shows no icon of its own. The palette, the CLI and MCP keep
/// the action. Lookups here are quiet: building a menu never refuses.
@MainActor
enum IconMenuVisibility {
    static func install(_ registry: ActionRegistry, context: AppActionContext) {
        hide("workspace.clearIcon", registry) { lookup(try? context.workspace($0).model) { $0.icon } }
        hide("workspaceGroup.clearIcon", registry) { lookup(try? context.group($0)) { $0.icon } }
        hide("space.clearIcon", registry) { lookup(try? context.room($0)) { $0.icon } }
        hide("browserProfile.clearIcon", registry) { lookup(try? context.browserProfile($0)) { $0.icon } }
        hide("tab.clearIcon", registry) { invocation in
            guard let target = invocation.target, target.kind == .tab else { return nil }
            return lookup(context.targetTab(target.id, invocation)?.0) { $0.userIcon }
        }
        hide("screenGroup.clearIcon", registry) { invocation in
            guard let target = invocation.target, target.kind == .screenGroup else { return nil }
            return lookup(GroupOwnership.screenGroup(ScreenGroupID(rawValue: target.id), machines: context.services.machines)) { $0.group.icon }
        }
        hide("tabGroup.clearIcon", registry) { invocation in
            guard let target = invocation.target, target.kind == .tabGroup else { return nil }
            let group = TabGroupID(rawValue: target.id)
            return lookup(GroupOwnership.pane(holdingTabGroup: group, machines: context.services.machines)) { owner in
                owner.pane.tabGroups.first { $0.id == group }?.icon
            }
        }
        hide("screen.clearIcon", registry) { invocation in
            guard let target = invocation.target, target.kind == .screen else { return nil }
            let screens = context.services.machines.daemons.lazy.flatMap(\.store.workspaces).flatMap(\.screens)
            return lookup(screens.first { $0.id == target.id }) { $0.icon }
        }
    }

    /// Whether a resolved target shows an icon of its own; nil when the
    /// target did not resolve.
    private static func lookup<Object>(_ object: Object?, _ icon: (Object) -> String?) -> Bool? {
        object.map { !(icon($0) ?? "").isEmpty }
    }

    /// Hides `id` for a resolved target without an icon. An unresolved
    /// target keeps the row (its handler reports why).
    private static func hide(_ id: ActionID, _ registry: ActionRegistry, hasIcon: @escaping @MainActor (ActionInvocation) -> Bool?) {
        ActionTargetVisibility.hide(id, in: registry) { hasIcon($0) == false }
    }
}
