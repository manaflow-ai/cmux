import Combine
import CmuxFileWatch
import CmuxSocketControl
import Foundation
import os


// MARK: - Managed Settings Application and Backups
extension CmuxSettingsFileStore {
    func applyManagedSettings(
        snapshot: ResolvedSettingsSnapshot,
        importedManagedDefaults: [String: ManagedSettingsValue],
        changedManagedDefaultKeys: Set<String>,
        updateBackups: Bool = true,
        applyLiveDefaultSideEffects: Bool,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) {
        var backups = loadBackups()
        var sideEffects = ManagedDefaultBatchSideEffects()
        let currentManagedIdentifiers = Set(backups.keys)
        let nextManagedIdentifiers = Set(snapshot.managedUserDefaults.keys)
            .union(snapshot.managedCustomSettings.managedIdentifiers)
        synchronized {
            isApplyingManagedSettings = true
        }
        defer {
            synchronized {
                isApplyingManagedSettings = false
            }
        }

        if updateBackups {
            for (defaultsKey, value) in snapshot.managedUserDefaults where backups[defaultsKey] == nil {
                backups[defaultsKey] = backupValueForUserDefaultsKey(defaultsKey, managedValue: value)
            }
            if snapshot.managedCustomSettings.socketPassword != nil,
               backups[Self.socketPasswordBackupIdentifier] == nil {
                backups[Self.socketPasswordBackupIdentifier] = currentSocketPasswordBackupValue()
            }
        }

        for identifier in currentManagedIdentifiers.subtracting(nextManagedIdentifiers) {
            guard let backup = backups[identifier] else { continue }
            sideEffects.merge(
                restoreBackup(
                    backup,
                    for: identifier,
                    synchronizeManagedAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
                )
            )
            backups.removeValue(forKey: identifier)
        }

        for (defaultsKey, value) in snapshot.managedUserDefaults {
            sideEffects.merge(
                applyManagedUserDefaultsValue(
                    value,
                    for: defaultsKey,
                    importedDefault: importedManagedDefaults[defaultsKey],
                    forceApply: changedManagedDefaultKeys.contains(defaultsKey),
                    synchronizeManagedAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme,
                    isDerivedFromLegacyWarnBeforeQuit: snapshot.legacyDerivedManagedUserDefaultKeys.contains(defaultsKey),
                    importedLegacyWarnBeforeQuitDefault: importedManagedDefaults[QuitWarningSettings.warnBeforeQuitKey]
                )
            )
        }
        applyManagedCustomSettings(snapshot.managedCustomSettings)
        if updateBackups {
            saveBackups(backups)
        }
        if applyLiveDefaultSideEffects {
            var sideEffectsToApply = drainDeferredManagedDefaultSideEffects()
            sideEffectsToApply.merge(sideEffects)
            applyManagedDefaultBatchSideEffects(sideEffectsToApply)
        } else {
            deferManagedDefaultSideEffects(applyLaunchManagedDefaultSideEffects(sideEffects))
        }
    }

    private func applyLaunchManagedDefaultSideEffects(
        _ sideEffects: ManagedDefaultBatchSideEffects
    ) -> ManagedDefaultBatchSideEffects {
        var deferredSideEffects = ManagedDefaultBatchSideEffects()
        for change in sideEffects.changes {
            if change.defaultsKey == AppearanceSettings.appearanceModeKey {
                AppearanceSettings.applyStoredMode(
                    rawValue: UserDefaults.standard.string(forKey: change.defaultsKey),
                    source: change.source,
                    duringLaunch: true,
                    synchronizeTerminalTheme: false,
                    environment: appearanceEnvironment
                )
            } else {
                deferredSideEffects.append(
                    defaultsKey: change.defaultsKey,
                    source: change.source,
                    synchronizeAppearanceTerminalTheme: change.synchronizeAppearanceTerminalTheme
                )
            }
        }
        return deferredSideEffects
    }

    private func deferManagedDefaultSideEffects(_ sideEffects: ManagedDefaultBatchSideEffects) {
        guard !sideEffects.isEmpty else { return }
        synchronized {
            deferredManagedDefaultSideEffects.merge(sideEffects)
        }
    }

    func drainDeferredManagedDefaultSideEffects() -> ManagedDefaultBatchSideEffects {
        synchronized {
            let deferred = deferredManagedDefaultSideEffects
            deferredManagedDefaultSideEffects = ManagedDefaultBatchSideEffects()
            return deferred
        }
    }

    private func applyManagedCustomSettings(_ settings: ManagedCustomSettings) {
        if let socketPassword = settings.socketPassword {
            switch socketPassword {
            case .set(let value):
                let current = (try? passwordStore.loadPassword()) ?? nil
                if current != value {
                    try? passwordStore.savePassword(value)
                }
            case .clear:
                let current = (try? passwordStore.loadPassword()) ?? nil
                if current != nil {
                    try? passwordStore.clearPassword()
                }
            }
        }
    }

    private func restoreBackup(
        _ backup: BackupValue,
        for identifier: String,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) -> ManagedDefaultBatchSideEffects {
        switch identifier {
        case Self.socketPasswordBackupIdentifier:
            switch backup {
            case .string(let value):
                try? passwordStore.savePassword(value)
            case .absent:
                try? passwordStore.clearPassword()
            default:
                break
            }
            return ManagedDefaultBatchSideEffects()
        default:
            return restoreUserDefaultsBackup(
                backup,
                for: identifier,
                synchronizeManagedAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
            )
        }
    }

    private func backupValueForUserDefaultsKey(_ defaultsKey: String, managedValue: ManagedSettingsValue) -> BackupValue {
        let defaults = UserDefaults.standard
        switch managedValue {
        case .bool:
            guard defaults.object(forKey: defaultsKey) != nil else { return .absent }
            return .bool(defaults.bool(forKey: defaultsKey))
        case .int:
            guard defaults.object(forKey: defaultsKey) != nil else { return .absent }
            return .int(defaults.integer(forKey: defaultsKey))
        case .double:
            guard defaults.object(forKey: defaultsKey) != nil else { return .absent }
            return .double(defaults.double(forKey: defaultsKey))
        case .string, .nullableString:
            guard let value = defaults.string(forKey: defaultsKey) else { return .absent }
            return .string(value)
        case .stringArray:
            guard let value = defaults.array(forKey: defaultsKey) as? [String] else { return .absent }
            return .stringArray(value)
        case .stringDictionary:
            if defaultsKey == WorkspaceTabColorSettings.paletteKey {
                guard let value = WorkspaceTabColorSettings.backupPaletteMap(defaults: defaults) else {
                    return .absent
                }
                return .stringDictionary(value)
            }
            guard let value = defaults.dictionary(forKey: defaultsKey) as? [String: String] else {
                return .absent
            }
            return .stringDictionary(value)
        }
    }

    private func currentSocketPasswordBackupValue() -> BackupValue {
        guard let current = try? passwordStore.loadPassword() else {
            return .absent
        }
        return .string(current)
    }

    private func restoreUserDefaultsBackup(
        _ backup: BackupValue,
        for defaultsKey: String,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) -> ManagedDefaultBatchSideEffects {
        let defaults = UserDefaults.standard
        if defaultsKey == WorkspaceTabColorSettings.paletteKey {
            switch backup {
            case .absent:
                WorkspaceTabColorSettings.reset(defaults: defaults)
            case .stringDictionary(let value):
                WorkspaceTabColorSettings.persistPaletteMap(value, defaults: defaults)
            default:
                break
            }
            return ManagedDefaultBatchSideEffects()
        }

        var didMutateStoredValue = false
        switch backup {
        case .absent:
            if defaults.object(forKey: defaultsKey) != nil {
                defaults.removeObject(forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .bool(let value):
            if defaults.object(forKey: defaultsKey) as? Bool != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .int(let value):
            if defaults.object(forKey: defaultsKey) as? Int != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .double(let value):
            if defaults.object(forKey: defaultsKey) as? Double != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .string(let value):
            if defaults.string(forKey: defaultsKey) != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .stringArray(let value):
            if defaults.array(forKey: defaultsKey) as? [String] != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .stringDictionary(let value):
            if defaults.dictionary(forKey: defaultsKey) as? [String: String] != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        }

        if didMutateStoredValue {
            return managedDefaultSideEffects(
                for: defaultsKey,
                source: "cmuxConfig.restoreUserDefault",
                synchronizeAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
            )
        }
        return ManagedDefaultBatchSideEffects()
    }

    private func applyManagedUserDefaultsValue(
        _ value: ManagedSettingsValue,
        for defaultsKey: String,
        importedDefault: ManagedSettingsValue?,
        forceApply: Bool,
        synchronizeManagedAppearanceTerminalTheme: Bool,
        isDerivedFromLegacyWarnBeforeQuit: Bool = false,
        importedLegacyWarnBeforeQuitDefault: ManagedSettingsValue? = nil
    ) -> ManagedDefaultBatchSideEffects {
        let defaults = UserDefaults.standard
        guard shouldApplyManagedUserDefaultsValue(
            value,
            for: defaultsKey,
            importedDefault: importedDefault,
            forceApply: forceApply,
            isDerivedFromLegacyWarnBeforeQuit: isDerivedFromLegacyWarnBeforeQuit,
            importedLegacyWarnBeforeQuitDefault: importedLegacyWarnBeforeQuitDefault,
            defaults: defaults
        ) else {
            return ManagedDefaultBatchSideEffects()
        }

        if defaultsKey == WorkspaceTabColorSettings.paletteKey,
           case .stringDictionary(let next) = value {
            let current = WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults)
            if current != next {
                WorkspaceTabColorSettings.persistPaletteMap(next, defaults: defaults)
            }
            return ManagedDefaultBatchSideEffects()
        }

        var didMutateStoredValue = false
        switch value {
        case .bool(let next):
            let current = defaults.object(forKey: defaultsKey) as? Bool
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .int(let next):
            let current = defaults.object(forKey: defaultsKey) as? Int
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .double(let next):
            let current = defaults.object(forKey: defaultsKey) as? Double
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .string(let next):
            let current = defaults.string(forKey: defaultsKey)
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .nullableString(let next):
            let current = defaults.string(forKey: defaultsKey)
            if current != next {
                if let next {
                    defaults.set(next, forKey: defaultsKey)
                } else {
                    defaults.removeObject(forKey: defaultsKey)
                }
                didMutateStoredValue = true
            }
        case .stringArray(let next):
            let current = defaults.array(forKey: defaultsKey) as? [String]
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .stringDictionary(let next):
            let current = defaults.dictionary(forKey: defaultsKey) as? [String: String]
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        }

        if didMutateStoredValue {
            return managedDefaultSideEffects(
                for: defaultsKey,
                source: "cmuxConfig.applyManagedDefault",
                synchronizeAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
            )
        }
        return ManagedDefaultBatchSideEffects()
    }

    private func shouldApplyManagedUserDefaultsValue(
        _ value: ManagedSettingsValue,
        for defaultsKey: String,
        importedDefault: ManagedSettingsValue?,
        forceApply: Bool,
        isDerivedFromLegacyWarnBeforeQuit: Bool,
        importedLegacyWarnBeforeQuitDefault: ManagedSettingsValue?,
        defaults: UserDefaults
    ) -> Bool {
        guard !forceApply else { return true }
        guard let importedDefault else { return true }
        // Precedence: user explicit choice (UserDefaults) > cmux.json imported default > built-in default.
        guard let current = currentManagedUserDefaultsValue(
            for: defaultsKey,
            matching: value,
            defaults: defaults
        ) else {
            return shouldApplyManagedUserDefaultsValueWhenCurrentIsMissing(
                value,
                for: defaultsKey,
                importedDefault: importedDefault,
                isDerivedFromLegacyWarnBeforeQuit: isDerivedFromLegacyWarnBeforeQuit,
                importedLegacyWarnBeforeQuitDefault: importedLegacyWarnBeforeQuitDefault,
                defaults: defaults
            )
        }
        return current == importedDefault
    }

    private func shouldApplyManagedUserDefaultsValueWhenCurrentIsMissing(
        _ value: ManagedSettingsValue,
        for defaultsKey: String,
        importedDefault: ManagedSettingsValue,
        isDerivedFromLegacyWarnBeforeQuit: Bool,
        importedLegacyWarnBeforeQuitDefault: ManagedSettingsValue?,
        defaults: UserDefaults
    ) -> Bool {
        if defaultsKey == QuitWarningSettings.confirmQuitKey,
           isDerivedFromLegacyWarnBeforeQuit,
           case .bool(let importedLegacyValue)? = importedLegacyWarnBeforeQuitDefault,
           let currentLegacyValue = defaults.object(forKey: QuitWarningSettings.warnBeforeQuitKey) as? Bool,
           currentLegacyValue != importedLegacyValue {
            return false
        }
        switch (value, importedDefault) {
        case (.nullableString, .nullableString(nil)):
            return true
        case (.nullableString, _):
            return false
        default:
            return true
        }
    }

    private func currentManagedUserDefaultsValue(
        for defaultsKey: String,
        matching value: ManagedSettingsValue,
        defaults: UserDefaults
    ) -> ManagedSettingsValue? {
        switch value {
        case .bool:
            guard let current = defaults.object(forKey: defaultsKey) as? Bool else { return nil }
            return .bool(current)
        case .int:
            guard let current = defaults.object(forKey: defaultsKey) as? Int else { return nil }
            return .int(current)
        case .double:
            guard let current = defaults.object(forKey: defaultsKey) as? Double else { return nil }
            return .double(current)
        case .string:
            guard let current = defaults.string(forKey: defaultsKey) else { return nil }
            return .string(current)
        case .nullableString:
            guard let current = defaults.object(forKey: defaultsKey) as? String else { return nil }
            return .nullableString(current)
        case .stringArray:
            guard let current = defaults.array(forKey: defaultsKey) as? [String] else { return nil }
            return .stringArray(current)
        case .stringDictionary:
            if defaultsKey == WorkspaceTabColorSettings.paletteKey {
                return .stringDictionary(WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults))
            }
            guard let current = defaults.dictionary(forKey: defaultsKey) as? [String: String] else {
                return nil
            }
            return .stringDictionary(current)
        }
    }

    private func managedDefaultSideEffects(
        for defaultsKey: String,
        source: String,
        synchronizeAppearanceTerminalTheme: Bool
    ) -> ManagedDefaultBatchSideEffects {
        var sideEffects = ManagedDefaultBatchSideEffects()
        sideEffects.append(
            defaultsKey: defaultsKey,
            source: source,
            synchronizeAppearanceTerminalTheme: synchronizeAppearanceTerminalTheme
        )
        return sideEffects
    }

    func applyManagedDefaultBatchSideEffects(_ sideEffects: ManagedDefaultBatchSideEffects) {
        guard !sideEffects.isEmpty else { return }
        let notificationCenter = notificationCenter
        let changes = sideEffects.changes
        let apply = {
            var agentSessionAutoResumeDidChange = false
            var agentHibernationDidChange = false
            for change in changes {
                if change.defaultsKey == TerminalScrollBarSettings.showScrollBarKey {
                    TerminalScrollBarSettings.notifyDidChange(notificationCenter: notificationCenter)
                }

                if change.defaultsKey == TerminalCopyOnSelectSettings.copyOnSelectKey {
                    TerminalCopyOnSelectSettings.notifyDidChange(notificationCenter: notificationCenter)
                }

                if change.defaultsKey == AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey {
                    agentSessionAutoResumeDidChange = true
                }
                if change.defaultsKey == AgentHibernationSettings.enabledKey ||
                    change.defaultsKey == AgentHibernationSettings.idleSecondsKey ||
                    change.defaultsKey == AgentHibernationSettings.maxLiveTerminalsKey ||
                    change.defaultsKey == AgentHibernationSettings.confirmationSecondsKey {
                    agentHibernationDidChange = true
                }

                if change.defaultsKey == LanguageSettings.languageKey {
                    let rawValue = UserDefaults.standard.string(forKey: change.defaultsKey) ?? ""
                    LanguageSettings.apply(AppLanguage(rawValue: rawValue) ?? .system)
                } else if change.defaultsKey == AppearanceSettings.appearanceModeKey {
                    AppearanceSettings.applyStoredMode(
                        rawValue: UserDefaults.standard.string(forKey: change.defaultsKey),
                        source: change.source,
                        duringLaunch: !change.synchronizeAppearanceTerminalTheme,
                        synchronizeTerminalTheme: change.synchronizeAppearanceTerminalTheme,
                        environment: self.appearanceEnvironment
                    )
                } else if change.defaultsKey == AppIconSettings.modeKey {
                    AppIconSettings.applyIcon(AppIconSettings.resolvedMode())
                }
            }

            if agentSessionAutoResumeDidChange {
                AgentSessionAutoResumeSettings.notifyDidChange(notificationCenter: notificationCenter)
            }
            if agentHibernationDidChange {
                AgentHibernationSettings.notifyDidChange(notificationCenter: notificationCenter)
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async { apply() }
        }
    }

    static func loadImportedManagedDefaults() -> [String: ManagedSettingsValue] {
        let defaults = UserDefaults.standard
        var imported: [String: ManagedSettingsValue]
        if let data = defaults.data(forKey: importedManagedDefaultsDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: ManagedSettingsValue].self, from: data) {
            imported = decoded
        } else {
            imported = [:]
        }

        if imported[SidebarMatchTerminalBackgroundSettings.userDefaultsKey] == nil,
           let legacyValue = defaults.object(
               forKey: SidebarMatchTerminalBackgroundSettings.legacyAppliedSettingsFileDefaultKey
           ) as? Bool {
            imported[SidebarMatchTerminalBackgroundSettings.userDefaultsKey] = .bool(legacyValue)
        }
        if imported[QuitWarningSettings.confirmQuitKey] == nil,
           case .bool(let importedLegacyValue)? = imported[QuitWarningSettings.warnBeforeQuitKey] {
            imported[QuitWarningSettings.confirmQuitKey] = .string(
                (importedLegacyValue ? QuitConfirmationMode.always : .never).rawValue
            )
        }
        return imported
    }

    func saveImportedManagedDefaults(_ imported: [String: ManagedSettingsValue]) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SidebarMatchTerminalBackgroundSettings.legacyAppliedSettingsFileDefaultKey)
        guard !imported.isEmpty else {
            defaults.removeObject(forKey: Self.importedManagedDefaultsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(imported) else { return }
        defaults.set(data, forKey: Self.importedManagedDefaultsDefaultsKey)
    }

    private func loadBackups() -> [String: BackupValue] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.backupsDefaultsKey),
              let backups = try? JSONDecoder().decode([String: BackupValue].self, from: data) else {
            return [:]
        }
        return backups
    }

    private func saveBackups(_ backups: [String: BackupValue]) {
        let defaults = UserDefaults.standard
        if backups.isEmpty {
            defaults.removeObject(forKey: Self.backupsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(backups) else { return }
        defaults.set(data, forKey: Self.backupsDefaultsKey)
    }

}
