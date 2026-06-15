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
        // Honor the action's own first-stroke policy: most actions require a
        // modifier (so a bare key never steals plain typing), but vim-style
        // diff-viewer actions accept a bare first stroke like `j`.
        guard let proposed = Self.parseStoredShortcut(
            from: combo,
            allowBareFirstStroke: action.allowsBareFirstStroke
        ) else {
            throw SettingsControlError.invalidShortcut(
                action: actionID,
                reason: "could not parse '\(combo)'. Use e.g. 'cmd+t', a chord 'ctrl+b c', or 'none' to unbind."
            )
        }

        // Numbered actions (e.g. Select Surface 1…9) are matched by digit. The
        // app drops a non-digit binding on reload, so reject it up front instead
        // of reporting a false success.
        if action.usesNumberedDigitMatching, !proposed.isUnbound, !Self.isNumberedDigitBinding(proposed) {
            throw SettingsControlError.invalidShortcut(
                action: actionID,
                reason: "this action is matched by number: bind it to a 1–9 key (e.g. 'cmd+1')."
            )
        }

        var bindings = await currentShortcutBindings()

        // Find every action whose effective binding truly collides: keystrokes
        // overlap AND focus contexts can coexist without priority routing
        // resolving the overlap (matching the app's router / Settings UI, so
        // context-separated bindings like browser-only vs markdown-only are not
        // falsely flagged).
        let conflicts = await conflictingActions(with: proposed, for: action, in: bindings)
        if !conflicts.isEmpty {
            guard force else {
                throw SettingsControlError.shortcutConflict(
                    action: actionID,
                    conflictingAction: conflicts[0].rawValue,
                    binding: proposed.configIdentifier
                )
            }
            // `--force` reassigns the keystroke: unbind the losing actions so the
            // running app routes the stroke to this action alone (leaving two
            // actions on one stroke would make the new binding silently not fire).
            for losing in conflicts {
                bindings[losing.rawValue] = .unbound
            }
        }

        bindings[action.rawValue] = proposed
        try await writeShortcutBindings(bindings)
        return shortcutRow(action, overrides: bindings)
    }

    /// The actions whose effective binding collides with `proposed` for `action`,
    /// honoring numbered-digit matching, focus context, and priority routing.
    private func conflictingActions(
        with proposed: StoredShortcut,
        for action: ShortcutAction,
        in bindings: [String: StoredShortcut]
    ) async -> [ShortcutAction] {
        guard !proposed.isUnbound else { return [] }
        let whenClauses = await currentShortcutWhenClauses()
        let actionWhen = effectiveWhenClause(action, whenClauses)
        var result: [ShortcutAction] = []
        for other in ShortcutAction.allCases where other != action {
            let otherBinding = effectiveBinding(other, overrides: bindings)
            guard otherBinding.conflicts(
                with: proposed,
                selfUsesNumberedDigitMatching: other.usesNumberedDigitMatching,
                otherUsesNumberedDigitMatching: action.usesNumberedDigitMatching
            ) else { continue }
            let otherWhen = effectiveWhenClause(other, whenClauses)
            guard ShortcutWhenClause.bindingsCollide(
                otherWhen, lhsHasPriority: other.hasPriorityShortcutRouting,
                actionWhen, rhsHasPriority: action.hasPriorityShortcutRouting
            ) else { continue }
            result.append(other)
        }
        return result
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

    func currentShortcutWhenClauses() async -> [String: String] {
        await stores.json.value(for: catalog.shortcuts.when)
    }

    /// The action's effective focus context: a parsed `shortcuts.when` override
    /// if present and valid, else the action's built-in default clause.
    func effectiveWhenClause(_ action: ShortcutAction, _ overrides: [String: String]) -> ShortcutWhenClause {
        if let raw = overrides[action.rawValue], let parsed = ShortcutWhenClause.parse(raw) {
            return parsed
        }
        return action.defaultFocusWhenClause
    }

    /// Whether a binding's matched stroke is a `1`–`9` digit (single-stroke: the
    /// first stroke; chord: the second). Numbered actions require this.
    static func isNumberedDigitBinding(_ shortcut: StoredShortcut) -> Bool {
        func isDigit(_ stroke: ShortcutStroke) -> Bool {
            guard let value = Int(stroke.key) else { return false }
            return (1...9).contains(value)
        }
        if let second = shortcut.second { return isDigit(second) }
        return isDigit(shortcut.first)
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
    /// (`["ctrl+b","c"]`). `none` / empty unbinds. `allowBareFirstStroke` is the
    /// action's own policy (see ``ShortcutAction/allowsBareFirstStroke``).
    static func parseStoredShortcut(from combo: String, allowBareFirstStroke: Bool) -> StoredShortcut? {
        let trimmed = combo.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return StoredShortcut.parseConfig(strokes: array, allowBareFirstStroke: allowBareFirstStroke)
            }
            return nil
        }
        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if tokens.count >= 2 {
            return StoredShortcut.parseConfig(strokes: Array(tokens.prefix(2)), allowBareFirstStroke: allowBareFirstStroke)
        }
        return StoredShortcut.parseConfig(trimmed, allowBareFirstStroke: allowBareFirstStroke)
    }
}
