import Foundation

/// User setting (opt-out, default on) for the warning shown when an agent
/// session is running in a pane that cmux is not tracking — i.e. its hooks were
/// bypassed (custom launcher / alias / shell function / PATH), so it won't resume
/// after a crash or update. Mirrors `AgentSessionAutoResumeSettings`.
enum UntrackedAgentSessionWarningSettings {
    static let warnUntrackedAgentSessionKey = "terminal.warnUntrackedAgentSession"
    static let defaultWarnUntrackedAgentSession = true
    static let didChangeNotification = Notification.Name("cmux.untrackedAgentSessionWarningSettingsDidChange")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: warnUntrackedAgentSessionKey) != nil else {
            return defaultWarnUntrackedAgentSession
        }
        return defaults.bool(forKey: warnUntrackedAgentSessionKey)
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: warnUntrackedAgentSessionKey)
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
        defaults.removeObject(forKey: warnUntrackedAgentSessionKey)
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
