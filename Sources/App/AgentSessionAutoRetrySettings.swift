import Foundation

enum AgentSessionAutoRetrySettings {
    static let autoRetryAgentSessionsKey = "terminal.autoRetryAgentSessions"
    static let defaultAutoRetryAgentSessions = false
    static let didChangeNotification = Notification.Name("cmux.agentSessionAutoRetrySettingsDidChange")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: autoRetryAgentSessionsKey) != nil else {
            return defaultAutoRetryAgentSessions
        }
        return defaults.bool(forKey: autoRetryAgentSessionsKey)
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: autoRetryAgentSessionsKey)
        if wasEnabled != enabled {
            notifyDidChange(notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.removeObject(forKey: autoRetryAgentSessionsKey)
        let didChange = wasEnabled != isEnabled(defaults: defaults)
        if didChange {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}
