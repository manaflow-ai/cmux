import Foundation

/// Captures and restores the pre-managed `UserDefaults` values that a managed
/// (administrator-imposed) default overrides, plus the managed socket-control
/// password backup.
///
/// When the settings-file store first applies a managed default for a key, it
/// records the key's current value here so the original can be reinstated once
/// the managed default is withdrawn (``backupValue(forUserDefaultsKey:managedValue:)``,
/// ``currentSocketPasswordBackupValue()``). When a managed default is removed,
/// ``restoreBackup(_:for:synchronizeManagedAppearanceTerminalTheme:)`` writes the
/// captured value back, returning the downstream side effects the store must
/// replay (notifications, appliers) for the keys it mutated.
///
/// The workspace tab-color palette key is special-cased through the injected
/// ``ManagedDefaultsPaletteSeam`` because its persistence is app-target logic
/// (`WorkspaceTabColorSettings`) the package cannot reference directly.
///
/// Isolation: a `Sendable` struct, not an actor. The settings-file store reads
/// and writes these values synchronously inside its own apply turns, the struct
/// holds no mutable state, and `UserDefaults` is documented thread-safe.
public struct ManagedDefaultsBackupService: Sendable {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let passwordStore: SocketControlPasswordStore
    private let paletteSeam: any ManagedDefaultsPaletteSeam

    /// Creates a backup engine reading and writing the given defaults suite.
    /// - Parameters:
    ///   - defaults: The defaults suite holding the managed keys' live values.
    ///   - passwordStore: The store for the managed socket-control password.
    ///   - paletteSeam: The app-provided palette persistence seam.
    public init(
        defaults: UserDefaults,
        passwordStore: SocketControlPasswordStore,
        paletteSeam: any ManagedDefaultsPaletteSeam
    ) {
        self.defaults = defaults
        self.passwordStore = passwordStore
        self.paletteSeam = paletteSeam
    }

    /// Restores the value captured under `identifier`, routing the socket-password
    /// identifier to the password store and every other identifier (a real
    /// `UserDefaults` key) through ``restoreUserDefaultsBackup(_:for:synchronizeManagedAppearanceTerminalTheme:)``.
    /// - Returns: The downstream side effects the caller must replay for any key
    ///   whose stored value changed.
    public func restoreBackup(
        _ backup: ManagedDefaultBackupValue,
        for identifier: String,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) -> ManagedDefaultBatchSideEffects {
        switch identifier {
        case ManagedDefaultBackupValue.socketPasswordBackupIdentifier:
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

    /// Captures the current `UserDefaults` value for `defaultsKey` (typed by
    /// `managedValue`) so it can be restored when the managed default is withdrawn,
    /// returning `.absent` when no user value is stored.
    public func backupValue(
        forUserDefaultsKey defaultsKey: String,
        managedValue: ManagedSettingsValue
    ) -> ManagedDefaultBackupValue {
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
            if defaultsKey == paletteSeam.paletteKey {
                guard let value = paletteSeam.backupPaletteMap(defaults: defaults) else {
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

    /// Captures the current socket-control password as a backup value, returning
    /// `.absent` when none is stored.
    public func currentSocketPasswordBackupValue() -> ManagedDefaultBackupValue {
        guard let current = try? passwordStore.loadPassword() else {
            return .absent
        }
        return .string(current)
    }

    private func restoreUserDefaultsBackup(
        _ backup: ManagedDefaultBackupValue,
        for defaultsKey: String,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) -> ManagedDefaultBatchSideEffects {
        if defaultsKey == paletteSeam.paletteKey {
            switch backup {
            case .absent:
                paletteSeam.reset(defaults: defaults)
            case .stringDictionary(let value):
                paletteSeam.persistPaletteMap(value, defaults: defaults)
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
            var sideEffects = ManagedDefaultBatchSideEffects()
            sideEffects.append(
                defaultsKey: defaultsKey,
                source: "cmuxConfig.restoreUserDefault",
                synchronizeAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
            )
            return sideEffects
        }
        return ManagedDefaultBatchSideEffects()
    }
}
