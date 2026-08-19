import CmuxSettings

extension ShortcutListModel {
    func ingestPrefix(_ prefix: StoredShortcut) {
        let normalized = ShortcutPrefixPolicy().normalized(prefix) ?? .unbound
        self.prefix = normalized
        prefixRejection = nil
    }

    /// The localized validation message for the last rejected prefix attempt.
    var prefixValidationMessage: String? {
        switch prefixRejection {
        case .singleStrokeRequired:
            return String(
                localized: "shortcut.prefix.error.singleStrokeRequired",
                defaultValue: "The prefix must be one keystroke."
            )
        case .emptyStrokeNotSupported:
            return String(
                localized: "shortcut.prefix.error.emptyStrokeNotSupported",
                defaultValue: "The prefix key could not be recorded."
            )
        case .modifierRequired:
            return String(
                localized: "shortcut.prefix.error.modifierRequired",
                defaultValue: "Use a modifier key, or Space, for the prefix."
            )
        case .systemDefinedKeyNotSupported:
            return String(
                localized: "shortcut.prefix.error.systemDefinedKeyNotSupported",
                defaultValue: "Media and system-defined keys cannot be prefixes."
            )
        case .escapeReserved:
            return String(
                localized: "shortcut.prefix.error.escapeReserved",
                defaultValue: "Escape is reserved for cancelling an armed prefix."
            )
        case .accepted, .unbound, nil:
            return nil
        }
    }

    /// Dismisses the prefix validation message without changing persistence.
    func clearPrefixRejection() {
        prefixRejection = nil
    }

    /// Whether the row recorder should collect two strokes for `action`.
    /// Existing persisted chords remain editable as chords; a temporary
    /// override is used only for the current Settings session.
    func chordsEnabled(for action: ShortcutAction) -> Bool {
        guard action.allowsChordShortcut else { return false }
        if let override = chordModeOverrides[action.rawValue] {
            return override
        }
        return effective(for: action)?.hasChord == true
    }

    /// Toggles the row recorder between single-stroke and chord capture.
    func toggleChordMode(for action: ShortcutAction) {
        guard action.allowsChordShortcut else { return }
        let next = !chordsEnabled(for: action)
        chordModeOverrides[action.rawValue] = next
        if next {
            chordModeActions.insert(action.rawValue)
        } else {
            chordModeActions.remove(action.rawValue)
        }
    }

    /// Clears a temporary recorder-mode override after a binding is committed.
    func clearChordModeOverride(for action: ShortcutAction) {
        chordModeOverrides.removeValue(forKey: action.rawValue)
        chordModeActions.remove(action.rawValue)
    }

    /// Records the optional global prefix stroke. Prefix validation lives in
    /// CmuxSettings so file, UI, and runtime paths share one grammar.
    func assignPrefix(_ stroke: ShortcutStroke) async {
        let policy = ShortcutPrefixPolicy()
        guard let normalized = policy.normalized(stroke) else {
            prefixRejection = policy.result(for: StoredShortcut(first: stroke))
            return
        }
        prefixRejection = nil
        await rebaseChordBindings(to: normalized)
        await writePrefix(StoredShortcut(first: normalized))
    }

    /// Disables the global prefix layer while preserving action bindings.
    func clearPrefix() async {
        prefixRejection = nil
        await writePrefix(.unbound)
    }
}
