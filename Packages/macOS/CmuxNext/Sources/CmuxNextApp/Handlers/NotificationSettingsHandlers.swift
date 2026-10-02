import CmuxNextActions
import CmuxNextSettings
import os

/// Notification preference verbs: mute a workspace, banners on or off, and
/// the dismissal policy. Each applies to `NotificationCenterService` at once
/// and writes cmux.json, which owns settings (the watcher reapplies it).
/// Banners and dismissal are schema keys and go through the validated
/// `setSetting` path; the muted workspace list has no schema entry.
enum NotificationSettingsHandlers {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

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
            write(context, "mute workspace") { try await $0.set(list, at: ["notifications", "mutedWorkspaces"]) }
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

    /// Raw write for `notifications.mutedWorkspaces`, which is not a schema setting.
    private static func write(_ context: AppActionContext, _ label: String,
                              _ body: @escaping @Sendable (SettingsController) async throws -> Void) {
        guard let settings = context.services.settings else { return }
        Task {
            do { try await body(settings) } catch {
                logger.error("\(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
