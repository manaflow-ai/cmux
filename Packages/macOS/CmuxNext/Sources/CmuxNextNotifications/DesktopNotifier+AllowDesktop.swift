import AppKit
package import CmuxNextActions
import CmuxNextCompat

extension DesktopNotifier {
    /// Allow Desktop Notifications (`cmux setup notifications`): the prompt `notifications.request` shows;
    /// denied opens the System Settings pane only the person can use.
    package func bindAllowDesktop(into registry: ActionRegistry) {
        registry.bindEffect("notifications.allowDesktop", effect: { [weak self] _ in
            guard let center = try? self?.permission() else { return .refused(NotificationPermission.unavailableMessage) }
            // action-wait-allow: macOS shows its own prompt, and the answer is the person's click there.
            return .waiting(.externalProcess) {
                guard let permission = try? await center.request() else { return ActionWorkFailure(NotificationPermission.unavailableMessage) }
                if permission.isDenied, let pane = permission.settingsURL { NSWorkspace.shared.openInBackground(pane) }
                return nil
            }
        })
    }
}
