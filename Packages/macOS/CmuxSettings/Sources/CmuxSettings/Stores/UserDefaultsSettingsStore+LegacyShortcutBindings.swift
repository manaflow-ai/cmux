import Foundation

extension UserDefaultsSettingsStore {
    /// Returns shortcut overrides written by the legacy UserDefaults-backed Settings UI.
    ///
    /// Callers merge this snapshot below `cmux.json` bindings and above built-in defaults,
    /// matching the app's compatibility lookup order.
    public nonisolated func initialLegacyShortcutBindings() -> [String: StoredShortcut] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in
            let key = Self.legacyShortcutKey(for: action)
            guard let shortcut = storage.valueIfPresent(for: key) else { return nil }
            return (action.rawValue, shortcut)
        })
    }

    /// Removes the legacy UserDefaults override after an authoritative JSON binding is saved.
    ///
    /// - Parameter action: The shortcut action whose legacy value should be removed.
    public func resetLegacyShortcutBinding(for action: ShortcutAction) {
        let key = Self.legacyShortcutKey(for: action)
        guard storage.valueIfPresent(for: key) != nil else { return }
        reset(key)
    }

    /// Removes every legacy UserDefaults shortcut override after JSON defaults are reset.
    public func resetAllLegacyShortcutBindings() {
        for action in ShortcutAction.allCases {
            resetLegacyShortcutBinding(for: action)
        }
    }

    private nonisolated static func legacyShortcutKey(
        for action: ShortcutAction
    ) -> DefaultsKey<StoredShortcut> {
        DefaultsKey(
            id: "shortcuts.legacy.\(action.rawValue)",
            defaultValue: .unbound,
            userDefaultsKey: "shortcut.\(action.rawValue)"
        )
    }
}
