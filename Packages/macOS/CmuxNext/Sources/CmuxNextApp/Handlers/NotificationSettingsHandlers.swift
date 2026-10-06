import CmuxNextActions
import CmuxNextSettings

/// Notification preference verbs: mute a workspace, banners on or off, and
/// the dismissal policy. Each applies to `NotificationCenterService` at once
/// and writes cmux.json, which owns settings (the watcher reapplies it).
/// Every key is a schema key and goes through the validated `setSetting`
/// path (`AppActionContext.writeSetting`), so a managed key or a run that may
/// not change it is refused the same way as from Settings or `settings.set`.
enum NotificationSettingsHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let notifications = context.services.notifications
        registry.bind("notifications.toggleWorkspaceMute", run: { invocation in
            guard let workspace = context.scope(invocation).workspace else {
                throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn)
            }
            var muted = notifications.preferences.mutedWorkspaces
            if muted.remove(workspace.id) == nil { muted.insert(workspace.id) }
            notifications.preferences.mutedWorkspaces = muted
            let list = JSONValue.array(muted.sorted().map(JSONValue.string))
            context.writeSetting("mute workspace", ["notifications", "mutedWorkspaces"], list, reloadOnFailure: true)
        })
        registry.bind("notifications.toggleBanners", run: { _ in
            let next: DesktopNotificationMode = notifications.preferences.desktop == .never ? .unlessFocused : .never
            notifications.preferences.desktop = next
            context.writeSetting("toggle banners", ["notifications", "desktop"], .string(next.rawValue))
        })
        for mode in NotificationDismissal.allCases {
            registry.bind(ActionID(rawValue: "notifications.dismissal.\(mode.rawValue)"), run: { _ in
                notifications.preferences.dismissal = mode
                context.writeSetting("set dismissal", ["notifications", "dismissal"], .string(mode.rawValue))
            })
        }
    }
}
