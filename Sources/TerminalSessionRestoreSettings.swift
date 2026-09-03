import Foundation

/// Owns the defaults and notification dependencies for the terminal-session
/// restore preference.
///
/// Keeping those dependencies on a constructable value lets settings UI,
/// command-palette actions, managed-config imports, and restore policy tests
/// share the same mutation semantics without reaching through a static helper
/// namespace.
struct TerminalSessionRestoreSettings {
    static let restoreTerminalSessionsKey = "terminal.restoreTerminalSessions"
    static let defaultRestoreTerminalSessions = true
    static let didChangeNotification = Notification.Name(
        "cmux.terminalSessionRestoreSettingsDidChange"
    )

    let defaults: UserDefaults
    let notificationCenter: NotificationCenter

    /// Creates an owner with explicitly injectable persistence dependencies.
    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    /// The effective value, including the default for an unset key.
    var isEnabled: Bool {
        guard defaults.object(forKey: restoreTerminalSessionsKey) != nil else {
            return defaultRestoreTerminalSessions
        }
        return defaults.bool(forKey: restoreTerminalSessionsKey)
    }

    /// Persists a value and emits the change notification only when the
    /// effective setting changes.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        let wasEnabled = isEnabled
        defaults.set(enabled, forKey: restoreTerminalSessionsKey)
        if wasEnabled != enabled {
            notifyDidChange()
        }
        return wasEnabled != enabled
    }

    /// Removes an override and reports whether the effective value changed.
    @discardableResult
    func reset() -> Bool {
        let wasEnabled = isEnabled
        defaults.removeObject(forKey: restoreTerminalSessionsKey)
        let didChange = wasEnabled != isEnabled
        if didChange {
            notifyDidChange()
        }
        return didChange
    }

    /// Posts the notification used by restore observers after an external
    /// owner has committed the defaults value.
    func notifyDidChange() {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}
