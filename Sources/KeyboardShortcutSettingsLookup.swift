import Foundation

extension KeyboardShortcutSettings {
    private static func configuredShortcutIfPresent(for action: Action) -> (exists: Bool, shortcut: StoredShortcut?) {
        if let managedShortcut = settingsFileStore.override(for: action) {
            return (true, managedShortcut.isUnbound ? nil : managedShortcut)
        }

        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return (false, nil)
        }
        return (true, shortcut.isUnbound ? nil : shortcut)
    }

    private static func legacySurfaceSelectionShortcutIfPresent(for action: Action) -> (exists: Bool, shortcut: StoredShortcut?) {
        guard let digit = action.surfaceSelectionDigit else { return (false, nil) }

        let legacy = configuredShortcutIfPresent(for: .selectSurfaceByNumber)
        guard legacy.exists else { return (false, nil) }
        guard var shortcut = legacy.shortcut else { return (true, nil) }

        if shortcut.hasChord {
            shortcut.chordKey = String(digit)
        } else {
            shortcut.key = String(digit)
        }
        return (true, shortcut)
    }

    static func shortcutIfBound(for action: Action) -> StoredShortcut? {
        #if DEBUG
        shortcutLookupObserver?(action)
        #endif

        let configured = configuredShortcutIfPresent(for: action)
        if configured.exists {
            return configured.shortcut
        }

        let legacySurfaceSelection = legacySurfaceSelectionShortcutIfPresent(for: action)
        if legacySurfaceSelection.exists {
            return legacySurfaceSelection.shortcut
        }

        let defaultShortcut = action.defaultShortcut
        return defaultShortcut.isUnbound ? nil : defaultShortcut
    }

    static func shortcut(for action: Action) -> StoredShortcut {
        shortcutIfBound(for: action) ?? .unbound
    }

    static func hasExplicitShortcutConfiguration(for action: Action) -> Bool {
        configuredShortcutIfPresent(for: action).exists
    }

    static func menuShortcut(for action: Action) -> StoredShortcut {
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive else {
            return .unbound
        }
        return shortcut(for: action)
    }

    static func isManagedBySettingsFile(_ action: Action) -> Bool {
        settingsFileStore.isManagedByFile(action)
    }

    static func unbindShortcut(for action: Action) {
        setShortcut(.unbound, for: action)
    }

    static func settingsFileManagedSubtitle(for action: Action) -> String? {
        guard isManagedBySettingsFile(action) else { return nil }
        return String(localized: "settings.shortcuts.managedByFile", defaultValue: "Managed in cmux.json")
    }

}
