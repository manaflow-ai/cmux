import Foundation

extension KeyboardShortcutSettings {
    static func shortcutIfBound(for action: Action) -> StoredShortcut? {
        #if DEBUG
        shortcutLookupObserver?(action)
        #endif

        if let explicitShortcut = explicitShortcutOverride(for: action) {
            return explicitShortcut.isUnbound ? nil : explicitShortcut
        }

        if action == .searchAllPanels,
           shouldSuppressSearchAllPanelsDefaultForExplicitFindInDirectory() {
            return nil
        }

        let defaultShortcut = action.defaultShortcut
        return defaultShortcut.isUnbound ? nil : defaultShortcut
    }

    static func shortcut(for action: Action) -> StoredShortcut {
        shortcutIfBound(for: action) ?? .unbound
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

    private static func explicitShortcutOverride(for action: Action) -> StoredShortcut? {
        if let managedShortcut = settingsFileStore.override(for: action) {
            return managedShortcut
        }

        if let shortcut = userDefaultsShortcut(forKey: action.defaultsKey) {
            return shortcut
        }

        if action == .searchAllPanels,
           let shortcut = userDefaultsShortcut(forKey: legacyGlobalSearchDefaultsKey) {
            return shortcut
        }

        return nil
    }

    private static func userDefaultsShortcut(forKey key: String) -> StoredShortcut? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(StoredShortcut.self, from: data) else {
            return nil
        }
        return shortcut
    }

    private static func shouldSuppressSearchAllPanelsDefaultForExplicitFindInDirectory() -> Bool {
        guard explicitShortcutOverride(for: .searchAllPanels) == nil,
              let findShortcut = explicitShortcutOverride(for: .findInDirectory),
              !findShortcut.isUnbound else {
            return false
        }

        return findShortcut.configIdentifier == Action.searchAllPanels.defaultShortcut.configIdentifier
    }
}
