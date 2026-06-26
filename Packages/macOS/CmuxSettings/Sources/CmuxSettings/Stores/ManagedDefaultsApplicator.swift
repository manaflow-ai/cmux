import Foundation

/// Applies managed (administrator-imposed) `UserDefaults` values imported from
/// cmux.json, deciding per key whether the managed value should overwrite the
/// live value and returning the downstream side effects the settings-file store
/// must replay (notifications, appliers) for the keys it mutated.
///
/// Precedence it enforces: a user's explicit choice (a live `UserDefaults` value
/// differing from the previously imported managed default) wins over a managed
/// default. A managed default applies only when it is newly added/changed
/// (`forceApply`), when there is no prior imported default, or when the live
/// value still equals that prior imported default; a missing live value defers
/// to ``shouldApplyManagedUserDefaultsValueWhenCurrentIsMissing(_:for:importedDefault:isDerivedFromLegacyWarnBeforeQuit:importedLegacyWarnBeforeQuitDefault:defaults:)``.
///
/// The workspace tab-color palette key is special-cased through the injected
/// ``ManagedDefaultsPaletteSeam`` because its persistence and resolution are
/// app-target logic (`WorkspaceTabColorSettings`) the package cannot reference
/// directly.
///
/// Isolation: a `Sendable` struct, not an actor. The settings-file store calls
/// these methods synchronously inside its own apply turns, the struct holds no
/// mutable state, and `UserDefaults` is documented thread-safe.
public struct ManagedDefaultsApplicator: Sendable {
    private let paletteSeam: any ManagedDefaultsPaletteSeam

    /// Creates an applicator routing the palette key through `paletteSeam`.
    /// - Parameter paletteSeam: The app-provided palette persistence/resolution seam.
    public init(paletteSeam: any ManagedDefaultsPaletteSeam) {
        self.paletteSeam = paletteSeam
    }

    /// Applies the managed `value` for `defaultsKey` to `UserDefaults.standard`
    /// when precedence allows it, returning the side effects the caller must
    /// replay for the key when its stored value changed (an empty batch otherwise).
    /// - Parameters:
    ///   - value: The managed value imported from cmux.json.
    ///   - defaultsKey: The `UserDefaults` key being managed.
    ///   - importedDefault: The previously imported managed default for the key.
    ///   - forceApply: When true, applies regardless of the live value (newly
    ///     added/changed key).
    ///   - synchronizeManagedAppearanceTerminalTheme: Forwarded into the produced
    ///     side effects for appearance keys.
    ///   - isDerivedFromLegacyWarnBeforeQuit: Whether the key is the confirm-quit
    ///     mode derived from the legacy warn-before-quit flag.
    ///   - importedLegacyWarnBeforeQuitDefault: The imported legacy warn-before-quit
    ///     default, consulted only for that derived key.
    public func applyManagedUserDefaultsValue(
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

        if defaultsKey == paletteSeam.paletteKey,
           case .stringDictionary(let next) = value {
            let current = paletteSeam.resolvedPaletteMap(defaults: defaults)
            if current != next {
                paletteSeam.persistPaletteMap(next, defaults: defaults)
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
        if defaultsKey == AppCatalogSection().confirmQuitMode.userDefaultsKey,
           isDerivedFromLegacyWarnBeforeQuit,
           case .bool(let importedLegacyValue)? = importedLegacyWarnBeforeQuitDefault,
           let currentLegacyValue = defaults.object(forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey) as? Bool,
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
            if defaultsKey == paletteSeam.paletteKey {
                return .stringDictionary(paletteSeam.resolvedPaletteMap(defaults: defaults))
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
}
