public import CmuxSettings

extension StoredShortcut {
    /// Chord-aware match decision for a configured shortcut against a single
    /// keystroke, given the live two-stroke chord prefix and a per-stroke
    /// matcher.
    ///
    /// This is the pure decision skeleton lifted out of the app target's
    /// configured-shortcut routing: the app supplies `strokeMatches`, a closure
    /// that compares one ``ShortcutStroke`` against the live `NSEvent` (which
    /// stays app-side as a witness), and this method applies the legacy
    /// chord-state branching:
    ///
    /// - An unbound shortcut never matches.
    /// - While a chord prefix is active, only a shortcut whose first stroke is
    ///   that prefix and which has a second stroke can match, and it matches on
    ///   its second stroke.
    /// - With no active prefix, a chorded shortcut never matches a lone
    ///   keystroke; a single-stroke shortcut matches on its first stroke.
    ///
    /// - Parameters:
    ///   - activeChordPrefix: The first stroke of an in-progress chord, or `nil`
    ///     when no chord is armed for the current event.
    ///   - strokeMatches: Whether the given stroke matches the live event.
    /// - Returns: `true` when the shortcut matches under the current chord state.
    public func matchesConfigured(
        activeChordPrefix: ShortcutStroke?,
        strokeMatches: (ShortcutStroke) -> Bool
    ) -> Bool {
        guard !isUnbound else { return false }
        if let prefix = activeChordPrefix {
            guard let second, first == prefix else {
                return false
            }
            return strokeMatches(second)
        }
        guard !hasChord else { return false }
        return strokeMatches(first)
    }
}
