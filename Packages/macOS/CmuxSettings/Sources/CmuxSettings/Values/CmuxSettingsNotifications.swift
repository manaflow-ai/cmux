import Foundation

/// Notification names shared by the settings UI and the app host.
public extension Notification.Name {
    static let cmuxAgentHibernationSettingsDidChange = Notification.Name(
        "cmux.agentHibernationSettingsDidChange"
    )
}
