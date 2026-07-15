import Foundation

enum SystemWideHotkeySettings {
    static let enabledKey = "systemWideHotkey.enabled"
    static let legacyShortcutKey = "systemWideHotkey.shortcut"
    static let defaultEnabled = false
    static let action: KeyboardShortcutSettings.Action = .showHideAllWindows

    static var defaultShortcut: StoredShortcut { action.defaultShortcut }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    static func shortcut() -> StoredShortcut {
        migrateLegacyShortcutIfNeeded()
        if let managedShortcut = KeyboardShortcutSettings.settingsFileStore.override(for: action) {
            return managedShortcut
        }
        return storedShortcut() ?? defaultShortcut
    }

    static func setShortcut(_ shortcut: StoredShortcut) {
        migrateLegacyShortcutIfNeeded()
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
    }

    static func normalizedRecordedShortcutResult(
        _ shortcut: StoredShortcut
    ) -> KeyboardShortcutSettings.RecordedShortcutResolution {
        action.normalizedRecordedShortcutResult(shortcut)
    }

    static func normalizedRecordedShortcut(_ shortcut: StoredShortcut) -> StoredShortcut? {
        action.normalizedRecordedShortcut(shortcut)
    }

    static func isManagedBySettingsFile() -> Bool {
        KeyboardShortcutSettings.isManagedBySettingsFile(action)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: legacyShortcutKey)
        defaults.removeObject(forKey: action.defaultsKey)
    }

    private static func migrateLegacyShortcutIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: legacyShortcutKey) != nil else { return }
        defer { defaults.removeObject(forKey: legacyShortcutKey) }

        guard defaults.object(forKey: action.defaultsKey) == nil,
              let data = defaults.data(forKey: legacyShortcutKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return
        }

        let migratedShortcut = normalizedRecordedShortcut(shortcut) ?? shortcut
        guard let migratedData = try? JSONEncoder().encode(migratedShortcut) else { return }
        defaults.set(migratedData, forKey: action.defaultsKey)
    }

    private static func storedShortcut(defaults: UserDefaults = .standard) -> StoredShortcut? {
        guard let data = defaults.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return KeyboardShortcutSettings.settingsFileStore.override(for: action)
        }
        return shortcut
    }
}
