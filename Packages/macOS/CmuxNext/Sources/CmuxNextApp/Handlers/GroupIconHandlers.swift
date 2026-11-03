import CmuxNextActions
import CmuxNextDaemon
import Foundation

/// Set and remove the icon of a screen group (`screen-group-icon-v1`) or a
/// tab group (`tab-group-icon-v1`): the shared icon string, the same rule as
/// workspace group icons (`workspaceGroup.setIcon`). An icon argument (CLI,
/// MCP, scripts) sets it; without one (palette, chip menu) the shared icon
/// picker opens beside the group's chip and its pick takes the same path.
/// Every change goes through `IconHistory`, so a user's change offers an
/// undo. The group's own machine (`GroupOwnership`) takes the change and
/// stores an image or SVG pick.
enum GroupIconHandlers {
    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        bindScreenGroups(registry, ctx)
        bindTabGroups(registry, ctx)
    }

    private static func bindScreenGroups(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        let capability = DaemonCapability.screenGroupIcon.rawValue
        registry.bind("screenGroup.setIcon", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            guard let ref = ctx.screenGroup(invocation) else { return }
            try require(capability, on: ref.daemon)
            let history = IconHistory.screenGroup(ctx), id = ref.group.id.rawValue, current = ref.group.icon
            if let icon = try GroupIconArgument.icon(in: invocation) {
                return try history.change(id, from: current, to: icon, origin: invocation.origin)
            }
            guard let anchor = ctx.services.iconPicker.anchor(screenGroup: id) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen)
            }
            ctx.services.iconPicker.pick(current: current, target: "screenGroup:\(id)", at: anchor,
                                         assets: IconAssetStore.owner(ref.daemon)) { result in
                apply(result, history, id, from: current)
            }
        })
        registry.bind("screenGroup.clearIcon", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            guard let ref = ctx.screenGroup(invocation) else { return }
            try require(capability, on: ref.daemon)
            try IconHistory.screenGroup(ctx).change(ref.group.id.rawValue, from: ref.group.icon, to: nil, origin: invocation.origin)
        })
    }

    private static func bindTabGroups(_ registry: ActionRegistry, _ ctx: AppActionContext) {
        let capability = DaemonCapability.tabGroupIcon.rawValue
        registry.bind("tabGroup.setIcon", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            guard let (group, pane) = TabGroupHandlers.group(invocation, ctx) else { return }
            let daemon = ctx.services.daemon(for: pane)
            try require(capability, on: daemon)
            let history = IconHistory.tabGroup(ctx), id = group.rawValue
            let current = pane.tabGroups.first { $0.id == group }?.icon
            if let icon = try GroupIconArgument.icon(in: invocation) {
                return try history.change(id, from: current, to: icon, origin: invocation.origin)
            }
            guard let anchor = ctx.services.iconPicker.anchor(tabGroup: id) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWindowOpen)
            }
            ctx.services.iconPicker.pick(current: current, target: "tabGroup:\(id)", at: anchor,
                                         assets: IconAssetStore.owner(daemon)) { result in
                apply(result, history, id, from: current)
            }
        })
        registry.bind("tabGroup.clearIcon", requires: capability, daemon: ctx.services.activeDaemon, run: { invocation in
            guard let (group, pane) = TabGroupHandlers.group(invocation, ctx) else { return }
            try require(capability, on: ctx.services.daemon(for: pane))
            let current = pane.tabGroups.first { $0.id == group }?.icon
            try IconHistory.tabGroup(ctx).change(group.rawValue, from: current, to: nil, origin: invocation.origin)
        })
    }

    /// A pick from the icon picker: a valid icon sets it, a clear removes it.
    private static func apply(_ result: IconPickerResult, _ history: IconHistory, _ id: String, from current: String?) {
        switch result {
        case .set(let icon) where WorkspaceIconValue.isValid(icon, assets: true): try? history.change(id, from: current, to: icon, origin: .user)
        case .clear: try? history.change(id, from: current, to: nil, origin: .user)
        case .set, .cancel: break
        }
    }

    /// Throws the missing-capability reason unless the group's own daemon serves `capability`.
    private static func require(_ capability: String, on daemon: DaemonService) throws {
        guard daemon.supports(capability) else { throw ActionFailure(message: daemon.missingCapabilityMessage(capability)) }
    }

    /// Sends a tab group's icon change to the daemon that owns `pane`: the
    /// v2 `tab_group.update` where the pane's daemon serves state resources
    /// (the rule `PaneController.handleGroup` uses), else `update-tab-group`.
    /// A rejection re-pushes the daemon's truth into the strip.
    static func send(_ icon: FieldUpdate<String>, toTabGroup group: TabGroupID, in pane: PaneModel, daemon: DaemonService,
                     _ ctx: AppActionContext) {
        let v2 = daemon.store.servesStateResources && pane.resourceID != nil, id = group.rawValue
        TabGroupHandlers.run("update-tab-group", pane: pane, ctx) { connection, transaction in
            if v2 { return try await connection.state.updateTabGroup(id, icon: icon) }
            _ = try await connection.updateTabGroup(group, icon: icon, transaction: transaction)
        }
    }
}

/// The `icon` argument of Set Group Icon (CLI, MCP, scripts): trimmed, nil
/// when absent or empty (the picker opens), refused unless it is an emoji, an
/// SF Symbol this Mac draws, or a stored image or SVG asset.
enum GroupIconArgument {
    static func icon(in invocation: ActionInvocation) throws -> String? {
        guard let icon = invocation["icon"]?.stringValue?.trimmingCharacters(in: .whitespaces), !icon.isEmpty else { return nil }
        guard WorkspaceIconValue.isValid(icon, assets: true) else { throw ActionFailure.invalidTarget(WorkspaceVerbStrings.invalidIcon) }
        return icon
    }
}
