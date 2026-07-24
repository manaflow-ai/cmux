import CmuxSettings

extension ShortcutListModel {
    /// Whether the row recorder should collect two strokes for `action`.
    ///
    /// Existing chords stay in chord mode when Settings reopens. A user toggle
    /// temporarily overrides that inferred state until the next assignment.
    func chordsEnabled(for action: ShortcutAction) -> Bool {
        guard action.allowsChordShortcut else { return false }
        return chordModeOverrides[action.rawValue] ?? (effective(for: action)?.hasChord == true)
    }

    /// Toggles whether the action's recorder collects a two-stroke chord.
    func toggleChordMode(for action: ShortcutAction) {
        guard action.allowsChordShortcut else {
            setChordModeOverride(nil, for: action)
            return
        }
        setChordModeOverride(!chordsEnabled(for: action), for: action)
    }

    /// Whether `action` is currently unbound but has a cached stroke available to
    /// restore (drives the X → restore button swap).
    func canRestore(for action: ShortcutAction) -> Bool {
        let effectiveShortcut = effective(for: action)
        let isUnbound = effectiveShortcut?.isUnbound ?? true
        return isUnbound && restoreShortcuts[action.rawValue] != nil
    }
}
