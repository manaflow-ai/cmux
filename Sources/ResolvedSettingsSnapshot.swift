import CmuxSettings
import Foundation

struct ResolvedSettingsSnapshot {
    var path: String?
    var shortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    /// Per-action `when`-clause overrides parsed from `shortcuts.when` — gate a
    /// binding to a focus context (see ``ShortcutWhenClause``).
    var whenClauses: [KeyboardShortcutSettings.Action: ShortcutWhenClause] = [:]
    var managedUserDefaults: [String: ManagedSettingsValue] = [:]
    var legacyDerivedManagedUserDefaultKeys: Set<String> = []
    var managedCustomSettings = ManagedCustomSettings()

    mutating func fillMissingSettings(from fallback: ResolvedSettingsSnapshot) {
        if path == nil && (!fallback.shortcuts.isEmpty ||
            !fallback.managedUserDefaults.isEmpty ||
            !fallback.managedCustomSettings.isEmpty) {
            path = fallback.path
        }
        for (action, shortcut) in fallback.shortcuts where shortcuts[action] == nil {
            shortcuts[action] = shortcut
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

extension ResolvedSettingsSnapshot: ManagedSettingsProjecting {
    mutating func projectManagedDefault(_ value: ManagedSettingsValue, forKey key: String) {
        managedUserDefaults[key] = value
    }
}

enum ManagedStringOverride: Equatable {
    case set(String)
    case clear
}

struct ManagedCustomSettings: Equatable {
    var socketPassword: ManagedStringOverride?

    var isEmpty: Bool {
        socketPassword == nil
    }

    var managedIdentifiers: Set<String> {
        var identifiers: Set<String> = []
        if socketPassword != nil {
            identifiers.insert(ManagedDefaultBackupValue.socketPasswordBackupIdentifier)
        }
        return identifiers
    }

    mutating func fillMissingSettings(from fallback: ManagedCustomSettings) {
        if socketPassword == nil {
            socketPassword = fallback.socketPassword
        }
    }
}
