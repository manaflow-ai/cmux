import Foundation

/// Controls whether `Cmd+C` reflows wrapped terminal text when copying.
///
/// Defaults to enabled: copy rejoins application-hard-wrapped paragraph lines
/// and strips continuation indentation (see `CmuxCopyReflow`). Users who want
/// byte-for-byte copy can turn this off; raw copy is also always available on
/// the dedicated "Copy Raw" action regardless of this setting.
enum TerminalReflowCopySettings {
    static let reflowCopyKey = "terminal.reflowCopy"
    static let defaultReflowCopy = true
    static let didChangeNotification = Notification.Name("cmux.terminalReflowCopySettingsDidChange")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        storedValue(defaults: defaults) ?? defaultReflowCopy
    }

    static func storedValue(defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: reflowCopyKey) as? Bool
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: reflowCopyKey)
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
        defaults.removeObject(forKey: reflowCopyKey)
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
