import Foundation

/// Routes Settings navigation notifications to one standalone window or pane.
@MainActor
struct SettingsNavigationNotificationRouter {
    let scope: String?

    func accepts(_ notification: Notification) -> Bool {
        guard let scope else {
            return notification.object == nil
        }
        return notification.object as? String == scope
    }

    /// Posts the same payload shape as the legacy Settings navigation request.
    func post(target: SettingsSectionID, anchorID: String, highlight: Bool) {
        NotificationCenter.default.post(
            name: SettingsWindowRoot.navigationRequestName,
            object: scope,
            userInfo: [
                "target": target.rawValue,
                "anchor": anchorID,
                "highlight": highlight
            ]
        )
    }
}
