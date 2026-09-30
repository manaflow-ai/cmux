import Foundation

/// Notification names shared by the settings UI and the app host.
public enum CmuxSettingsNotifications {
    public static let agentHibernationSettingsDidChange = Notification.Name(
        "cmux.agentHibernationSettingsDidChange"
    )
}
