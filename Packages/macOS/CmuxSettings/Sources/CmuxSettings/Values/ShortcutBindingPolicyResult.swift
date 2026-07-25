/// The action-owned validity of a persisted shortcut's shape.
///
/// Persistence adapters use this result before accepting a binding so Settings,
/// `cmux.json`, and legacy `UserDefaults` cannot disagree about whether an
/// action can execute the stored shortcut.
public enum ShortcutBindingPolicyResult: Sendable, Equatable {
    /// The action can execute the shortcut shape.
    case accepted

    /// The action requires a modifier on this first stroke.
    case bareFirstStrokeNotAllowed

    /// The action does not support two-stroke shortcuts.
    case chordNotAllowed

    /// The foreground action cannot receive a system-defined media key.
    case systemDefinedMediaKeyNotAllowed
}

public extension ShortcutAction {
    /// Validates the representation-independent shape of a persisted shortcut.
    ///
    /// This policy intentionally excludes conflicts with other actions because
    /// conflict checks require the caller's complete effective-binding snapshot.
    ///
    /// - Parameter shortcut: The shortcut loaded or proposed by a persistence adapter.
    /// - Returns: The action-owned validity of the shortcut shape.
    func shortcutBindingPolicyResult(
        for shortcut: StoredShortcut
    ) -> ShortcutBindingPolicyResult {
        guard !shortcut.isUnbound else { return .accepted }

        if shortcut.hasChord && !allowsChordShortcut {
            return .chordNotAllowed
        }
        if rejectsSystemDefinedMediaKey(shortcut) {
            return .systemDefinedMediaKeyNotAllowed
        }

        let first = shortcut.first
        let supportsLegacyBareSpace = first.key.lowercased() == "space"
            && self != .globalSearch
        guard allowsBareFirstStroke
            || first.hasAnyModifier
            || supportsLegacyBareSpace else {
            return .bareFirstStrokeNotAllowed
        }

        return .accepted
    }
}
