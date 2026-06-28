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

    /// Chord-aware numbered-digit decision for a configured shortcut, mirroring
    /// ``matchesConfigured(activeChordPrefix:strokeMatches:)`` but resolving the
    /// matched stroke to a digit (1–9) instead of a boolean.
    ///
    /// The app supplies `digitForStroke`, which reads the live `NSEvent` to map
    /// a ``ShortcutStroke`` to its pressed digit. The branching preserves the
    /// legacy numbered-matcher guards exactly, including the redundant
    /// no-active-prefix `isUnbound` re-check.
    ///
    /// - Parameters:
    ///   - activeChordPrefix: The first stroke of an in-progress chord, or `nil`.
    ///   - digitForStroke: The digit the given stroke resolves to for the live
    ///     event, or `nil`.
    /// - Returns: The matched digit under the current chord state, or `nil`.
    public func numberedConfiguredDigit(
        activeChordPrefix: ShortcutStroke?,
        digitForStroke: (ShortcutStroke) -> Int?
    ) -> Int? {
        guard !isUnbound else { return nil }
        if let prefix = activeChordPrefix {
            guard let second, first == prefix else {
                return nil
            }
            return digitForStroke(second)
        }
        guard !isUnbound, !hasChord else { return nil }
        return digitForStroke(first)
    }

    /// Match decision for a `KeyboardShortcutSettings` action's event, routing to
    /// numbered-digit matching or full single-stroke matching per the action.
    ///
    /// Faithful relocation of the app target's stale-menu-shortcut matcher: an
    /// unbound shortcut never matches; an action that uses numbered-digit
    /// matching matches when its digit resolver yields a digit; otherwise a
    /// chorded shortcut never matches and a single-stroke shortcut defers to the
    /// full-stroke matcher. The app supplies both closures, which read the live
    /// `NSEvent`.
    ///
    /// - Parameters:
    ///   - usesNumberedDigitMatching: Whether the action matches by digit.
    ///   - numberedDigit: The digit the event resolves to, or `nil`.
    ///   - fullMatch: Whether the event fully matches this shortcut.
    /// - Returns: `true` when the event matches the shortcut for the action.
    public func matchesKeyboardShortcutEvent(
        usesNumberedDigitMatching: Bool,
        numberedDigit: () -> Int?,
        fullMatch: () -> Bool
    ) -> Bool {
        guard !isUnbound else { return false }
        if usesNumberedDigitMatching {
            return numberedDigit() != nil
        }
        guard !hasChord else { return false }
        return fullMatch()
    }

    /// The numbered digit for this shortcut's first stroke, ignoring chord state.
    ///
    /// Faithful relocation of the app target's non-chord numbered-digit helper:
    /// an unbound or chorded shortcut resolves to `nil`; otherwise the first
    /// stroke is mapped to a digit by the app-supplied resolver (which reads the
    /// live `NSEvent`).
    ///
    /// - Parameter digitForStroke: The digit the given stroke resolves to, or `nil`.
    /// - Returns: The first stroke's digit, or `nil`.
    public func firstStrokeNumberedDigit(
        digitForStroke: (ShortcutStroke) -> Int?
    ) -> Int? {
        guard !isUnbound, !hasChord else { return nil }
        return digitForStroke(first)
    }
}
