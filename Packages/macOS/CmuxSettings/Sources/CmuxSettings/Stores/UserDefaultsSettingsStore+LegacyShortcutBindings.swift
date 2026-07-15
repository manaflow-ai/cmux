import Foundation

extension UserDefaultsSettingsStore {
    /// Returns shortcut overrides written by the legacy UserDefaults-backed Settings UI.
    ///
    /// Callers merge this snapshot below `cmux.json` bindings and above built-in defaults,
    /// matching the app's compatibility lookup order.
    public nonisolated func initialLegacyShortcutBindings() -> [String: StoredShortcut] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in
            let key = Self.legacyShortcutKey(for: action)
            guard let data = storage.valueIfPresent(for: key),
                  let payload = try? JSONDecoder().decode(LegacyStoredShortcutPayload.self, from: data) else {
                return nil
            }
            return (action.rawValue, payload.storedShortcut)
        })
    }

    /// Removes the legacy UserDefaults override after an authoritative JSON binding is saved.
    ///
    /// - Parameter action: The shortcut action whose legacy value should be removed.
    public func resetLegacyShortcutBinding(for action: ShortcutAction) {
        let key = Self.legacyShortcutKey(for: action)
        guard storage.hasStoredValue(for: key.userDefaultsKey) else { return }
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
    ) -> DefaultsKey<Data> {
        DefaultsKey(
            id: "shortcuts.legacy.\(action.rawValue)",
            defaultValue: Data(),
            userDefaultsKey: "shortcut.\(action.rawValue)"
        )
    }
}
