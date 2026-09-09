import CmuxSettings

struct ResolvedSettingsSnapshot {
    var path: String?
    var shortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    var managedShortcutActions: Set<KeyboardShortcutSettings.Action> = []
    /// Per-action `when`-clause overrides parsed from `shortcuts.when` — gate a
    /// binding to a focus context (see ``ShortcutWhenClause``).
    var whenClauses: [KeyboardShortcutSettings.Action: ShortcutWhenClause] = [:]
    var managedUserDefaults: [String: ManagedSettingsValue] = [:]
    var legacyDerivedManagedUserDefaultKeys: Set<String> = []
    var managedCustomSettings = ManagedCustomSettings()

    mutating func fillMissingSettings(from fallback: ResolvedSettingsSnapshot) {
        if path == nil && (!fallback.managedShortcutActions.isEmpty ||
            !fallback.managedUserDefaults.isEmpty ||
            !fallback.managedCustomSettings.isEmpty) {
            path = fallback.path
        }
        let missingShortcutActions = fallback.managedShortcutActions
            .subtracting(managedShortcutActions)
        for action in missingShortcutActions {
            managedShortcutActions.insert(action)
            if let shortcut = fallback.shortcuts[action] {
                shortcuts[action] = shortcut
            }
        }
        for (action, clause) in fallback.whenClauses where whenClauses[action] == nil {
            whenClauses[action] = clause
        }
        for (key, value) in fallback.managedUserDefaults where managedUserDefaults[key] == nil {
            managedUserDefaults[key] = value
            if fallback.legacyDerivedManagedUserDefaultKeys.contains(key) {
                legacyDerivedManagedUserDefaultKeys.insert(key)
            }
        }
        managedCustomSettings.fillMissingSettings(from: fallback.managedCustomSettings)
    }
}
