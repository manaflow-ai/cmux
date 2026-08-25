import Foundation

/// User preference controlling whether persisted terminal-containing workspaces
/// are recreated during an app-session restore.
enum TerminalSessionRestoreSettings {
    static let restoreTerminalSessionsKey = "terminal.restoreTerminalSessions"
    static let defaultRestoreTerminalSessions = true
    static let didChangeNotification = Notification.Name(
        "cmux.terminalSessionRestoreSettingsDidChange"
    )

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: restoreTerminalSessionsKey) != nil else {
            return defaultRestoreTerminalSessions
        }
        return defaults.bool(forKey: restoreTerminalSessionsKey)
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: restoreTerminalSessionsKey)
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
        defaults.removeObject(forKey: restoreTerminalSessionsKey)
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
