import CmuxNextActions
import CmuxNextSettings
import CmuxNextWindowRules

/// Notification preference verbs: mute a workspace, banners on or off, and
/// the dismissal policy. Each applies to `NotificationCenterService` at once
/// and writes cmux.json, which owns settings (the watcher reapplies it).
/// Every key is a schema key and goes through the validated `setSetting`
/// path (`AppActionContext.writeSetting`), so a managed key or a run that may
/// not change it is refused the same way as from Settings or `settings.set`.
enum NotificationSettingsHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let notifications = context.services.notifications
        registry.bindEffect("notifications.toggleWorkspaceMute", requires: nil, effect: { invocation in
            guard let workspace = context.scope(invocation).workspace else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
            }
            guard let daemon = context.services.machines.daemons.first(where: { $0.store.workspace(id: workspace.id) === workspace }) else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
            }
            let key = NotificationWorkspaceKey.settingsKey(machine: daemon.machineID, workspace: workspace.id,
                                                            localMachine: context.services.machines.local.machineID)
            let muted = notifications.preferences.mutedWorkspaces
            // A remote mute saved before keys were qualified (NotificationWorkspaceKey.legacyRemoteKey) unmutes too.
            let legacy = NotificationWorkspaceKey.legacyRemoteKey(muted, machine: daemon.machineID, workspace: workspace.id,
                                                                  localMachine: context.services.machines.local.machineID,
                                                                  localHolds: { id in context.services.machines.local.store.workspace(id: id) != nil })
            guard let next = WindowRules().toggleMute(Array(muted), key: key, legacy: legacy) else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
            notifications.preferences.mutedWorkspaces = Set(next)
            let list = JSONValue.array(next.map(JSONValue.string))
            context.writeSetting("mute workspace", ["notifications", "mutedWorkspaces"], list, reloadOnFailure: true)
            return .done
        })
        // Dismiss Highlight (cx-epgo): hides the workspace's attention rings
        // until a newer notification; presentation only, nothing is written.
        registry.bind("notifications.dismissHighlight", run: { invocation in
            guard let workspace = context.scope(invocation).workspace else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
            }
            notifications.dismissHighlight(workspace)
        })
        registry.bind("notifications.toggleBanners", run: { _ in
            guard let next = WindowRules().toggleBanners(notifications.preferences.desktop.rawValue).flatMap(DesktopNotificationMode.init(rawValue:)) else { return }
            notifications.preferences.desktop = next
            context.writeSetting("toggle banners", ["notifications", "desktop"], .string(next.rawValue))
        })
        ActionTargetTitles.setPaletteSettingState("notifications.toggleBanners", in: registry) { notifications.preferences.desktop != .never }
        for mode in NotificationDismissal.allCases {
            registry.bind(ActionID(rawValue: "notifications.dismissal.\(mode.rawValue)"), run: { _ in
                notifications.preferences.dismissal = mode
                context.writeSetting("set dismissal", ["notifications", "dismissal"], .string(mode.rawValue))
            })
        }
    }
}
