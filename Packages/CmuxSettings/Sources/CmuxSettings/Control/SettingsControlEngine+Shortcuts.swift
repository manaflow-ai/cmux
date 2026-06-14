import Foundation

extension SettingsControlEngine {
    /// Every shortcut action with its current and default binding, sorted by id.
    public func shortcutsList() async -> [ShortcutRow] {
        let overrides = await currentShortcutBindings()
        return ShortcutAction.allCases
            .map { shortcutRow($0, overrides: overrides) }
            .sorted { $0.action < $1.action }
    }

    /// One action's binding. Throws on unknown action.
    public func shortcutGet(_ actionID: String) async throws -> ShortcutRow {
        let action = try shortcutAction(actionID)
        return shortcutRow(action, overrides: await currentShortcutBindings())
    }

    /// Assigns a binding (`cmd+t`, a chord `ctrl+b c` or `["ctrl+b","c"]`, or
    /// `none` to unbind). Rejects a binding already used by another action
    /// unless `force` is set. Throws on unknown action / unparseable combo /
    /// conflict.
    @discardableResult
    public func shortcutSet(_ actionID: String, combo: String, force: Bool = false) async throws -> ShortcutRow {
        let action = try shortcutAction(actionID)
        guard let proposed = Self.parseStoredShortcut(from: combo) else {
            throw SettingsControlError.invalidShortcut(
                action: actionID,
                reason: "could not parse '\(combo)'. Use e.g. 'cmd+t', a chord 'ctrl+b c', or 'none' to unbind."
            )
        }

        var bindings = await currentShortcutBindings()

        if !proposed.isUnbound, !force {
            for other in ShortcutAction.allCases where other != action {
                let otherBinding = effectiveBinding(other, overrides: bindings)
                if otherBinding.conflicts(with: proposed) {
                    throw SettingsControlError.shortcutConflict(
                        action: actionID,
                        conflictingAction: other.rawValue,
                        binding: proposed.configIdentifier
                    )
                }
            }
        }

        bindings[action.rawValue] = proposed
        try await writeShortcutBindings(bindings)
        return shortcutRow(action, overrides: bindings)
    }

    /// Clears an action's override, reverting to its default binding.
    @discardableResult
    public func shortcutUnset(_ actionID: String) async throws -> ShortcutRow {
        let action = try shortcutAction(actionID)
        var bindings = await currentShortcutBindings()
        bindings.removeValue(forKey: action.rawValue)
        try await writeShortcutBindings(bindings)
        return shortcutRow(action, overrides: bindings)
    }

    /// Clears every shortcut override, reverting all actions to defaults.
    public func shortcutsReset() async throws {
        try await writeShortcutBindings([:])
    }

    // MARK: - Helpers

    func shortcutAction(_ id: String) throws -> ShortcutAction {
        guard let action = ShortcutAction(rawValue: id) else {
            throw SettingsControlError.unknownAction(id)
        }
        return action
    }

    func currentShortcutBindings() async -> [String: StoredShortcut] {
        await stores.json.value(for: catalog.shortcuts.bindings)
    }

    func writeShortcutBindings(_ bindings: [String: StoredShortcut]) async throws {
        do {
            if bindings.isEmpty {
                try await stores.json.reset(catalog.shortcuts.bindings)
            } else {
                try await stores.json.set(bindings, for: catalog.shortcuts.bindings)
            }
        } catch {
            throw SettingsControlError.storage("failed to write shortcuts.bindings: \(error.localizedDescription)")
        }
    }

    func effectiveBinding(_ action: ShortcutAction, overrides: [String: StoredShortcut]) -> StoredShortcut {
        overrides[action.rawValue] ?? action.defaultShortcut ?? .unbound
    }

    func shortcutRow(_ action: ShortcutAction, overrides: [String: StoredShortcut]) -> ShortcutRow {
        let override = overrides[action.rawValue]
        let effective = override ?? action.defaultShortcut ?? .unbound
        let defaultBinding = action.defaultShortcut ?? .unbound
        return ShortcutRow(
            action: action.rawValue,
            binding: effective.configIdentifier,
            defaultBinding: defaultBinding.configIdentifier,
            isOverridden: override != nil
        )
    }

    /// Parses a CLI combo argument into a binding, accepting a single token
    /// (`cmd+t`), a space-separated chord (`ctrl+b c`), or a JSON array
    /// (`["ctrl+b","c"]`). `none` / empty unbinds.
    static func parseStoredShortcut(from combo: String) -> StoredShortcut? {
        let trimmed = combo.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return StoredShortcut.parseConfig(strokes: array)
            }
            return nil
        }
        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if tokens.count >= 2 {
            return StoredShortcut.parseConfig(strokes: Array(tokens.prefix(2)))
        }
        return StoredShortcut.parseConfig(trimmed)
    }
}
