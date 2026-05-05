import Foundation

private enum SocketControlModeDefaultMigration {
    static let defaultsKey = "socketControlModeDefaultMigrationVersion"
    static let version = 1
}

extension SocketControlSettings {
    static func migratePersistedModeIfNeeded(defaults: UserDefaults = .standard) {
        let currentMigrationVersion = defaults.integer(
            forKey: SocketControlModeDefaultMigration.defaultsKey
        )
        let requiresDefaultModeMigration =
            currentMigrationVersion < SocketControlModeDefaultMigration.version

        defer {
            if requiresDefaultModeMigration {
                defaults.set(
                    SocketControlModeDefaultMigration.version,
                    forKey: SocketControlModeDefaultMigration.defaultsKey
                )
            }
        }

        if let stored = defaults.string(forKey: appStorageKey) {
            let migrated = migrateMode(stored)
            let resolvedMode: SocketControlMode
            if requiresDefaultModeMigration && migrated == .cmuxOnly {
                resolvedMode = .automation
            } else {
                resolvedMode = migrated
            }

            if resolvedMode.rawValue != stored {
                defaults.set(resolvedMode.rawValue, forKey: appStorageKey)
            }
            return
        }

        if let legacy = defaults.object(forKey: legacyEnabledKey) as? Bool {
            defaults.set((legacy ? defaultMode : .off).rawValue, forKey: appStorageKey)
        }
    }
}
