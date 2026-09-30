import CmuxNextActions
import CmuxNextSettings
import os

/// Notification preference verbs: mute a workspace, banners on or off, and
/// the dismissal policy. Each applies to `NotificationCenterService` at once
/// and writes cmux.json, which owns settings (the watcher reapplies it).
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
            write(context, "toggle banners") { try await $0.set(.string(next.rawValue), at: ["notifications", "desktop"]) }
        })
        for mode in NotificationDismissal.allCases {
            registry.bind(ActionID(rawValue: "notifications.dismissal.\(mode.rawValue)"), run: { _ in
                notifications.preferences.dismissal = mode
                write(context, "set dismissal") { try await $0.set(.string(mode.rawValue), at: ["notifications", "dismissal"]) }
            })
        }
    }

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
