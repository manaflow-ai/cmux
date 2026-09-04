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

    /// The system-wide action requires Command, Option, or Control.
    case primaryModifierRequired

    /// The action does not support two-stroke shortcuts.
    case chordNotAllowed

    /// The foreground action cannot receive a system-defined media key.
    case systemDefinedMediaKeyNotAllowed

    /// The system reserves this shortcut before the action can execute it.
    case systemReservedShortcutNotAllowed
}

extension ShortcutAction {
    /// Validates the representation-independent shape of a persisted shortcut.
    ///
    /// This policy intentionally excludes conflicts with other actions because
    /// conflict checks require the caller's complete effective-binding snapshot.
    ///
    /// - Parameter shortcut: The shortcut loaded or proposed by a persistence adapter.
    /// - Returns: The action-owned validity of the shortcut shape.
    public func shortcutBindingPolicyResult(
        for shortcut: StoredShortcut
    ) -> ShortcutBindingPolicyResult {
        guard !shortcut.isUnbound else { return .accepted }

        if shortcut.hasChord && !allowsChordShortcut {
            return .chordNotAllowed
        }
        if rejectsSystemDefinedMediaKey(shortcut) {
            return .systemDefinedMediaKeyNotAllowed
        }
        if rejectsSystemReservedShortcut(shortcut) {
            return .systemReservedShortcutNotAllowed
        }

        let first = shortcut.first
        if self == .showHideAllWindows,
           !first.command,
           !first.option,
           !first.control {
            return .primaryModifierRequired
        }
        // A chord's first stroke is the shared leader, not an ordinary
        // action-owned shortcut.  Let the action-independent prefix policy
        // validate that leader (including bare Space) even when this action
        // would reject a bare *single*-stroke binding.  This keeps the JSON
        // store, recorder, and runtime in agreement for Space-prefixed chords.
        let isValidSharedPrefix = shortcut.hasChord
            && ShortcutPrefixPolicy().result(
                for: StoredShortcut(first: first)
            ) == .accepted
        let supportsLegacyBareSpace = first.key.lowercased() == "space"
            && self != .globalSearch
        guard allowsBareFirstStroke
            || first.hasAnyModifier
            || isValidSharedPrefix
            || supportsLegacyBareSpace else {
            return .bareFirstStrokeNotAllowed
        }

        return .accepted
    }

    /// Resolves a persisted candidate into the shortcut the action executes.
    ///
    /// Unsupported Show/Hide candidates fail closed because silently registering
    /// its default would create an unexpected system-wide hotkey. Other actions
    /// fall back to their valid built-in default.
    ///
    /// - Parameters:
    ///   - candidate: The configured shortcut, or `nil` when no override exists.
    ///   - conflictsWithReservedShortcut: Whether a normalized shortcut is reserved
    ///     by a higher-priority system-wide binding.
    /// - Returns: The executable shortcut, or `nil` when the action is unbound.
    public func effectivePersistedShortcut(
        _ candidate: StoredShortcut?,
        conflictsWithReservedShortcut: (StoredShortcut) -> Bool = { _ in false }
    ) -> StoredShortcut? {
        effectivePersistedShortcut(
            candidate,
            normalizing: { shortcut in
                shortcutBindingPolicyResult(for: shortcut) == .accepted
                    ? shortcut.canonicalized()
                    : nil
            },
            conflictsWithReservedShortcut: conflictsWithReservedShortcut
        )
    }

    /// Resolves a persisted candidate using the consumer's runtime normalizer.
    ///
    /// - Parameters:
    ///   - candidate: The configured shortcut, or `nil` when no override exists.
    ///   - normalizing: Returns the executable representation of a shortcut, or
    ///     `nil` when the consumer cannot execute it.
    ///   - conflictsWithReservedShortcut: Whether a normalized shortcut is reserved
    ///     by a higher-priority system-wide binding.
    /// - Returns: The executable shortcut, or `nil` when the action is unbound.
    public func effectivePersistedShortcut(
        _ candidate: StoredShortcut?,
        normalizing: (StoredShortcut) -> StoredShortcut?,
        conflictsWithReservedShortcut: (StoredShortcut) -> Bool
    ) -> StoredShortcut? {
        if let candidate {
            if candidate.isUnbound {
                return nil
            }
            if let normalized = normalizing(candidate),
               !conflictsWithReservedShortcut(normalized) {
                return normalized
            }
            if self == .showHideAllWindows {
                return nil
            }
        }

        guard let defaultShortcut,
              !defaultShortcut.isUnbound,
              let normalizedDefault = normalizing(defaultShortcut),
              !conflictsWithReservedShortcut(normalizedDefault) else {
            return nil
        }
        return normalizedDefault
    }
}
