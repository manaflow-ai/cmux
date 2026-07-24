import CmuxSettings

/// Whether two shortcut first-strokes collide, accounting for numbered-digit
/// families.
///
/// A numbered binding (``ShortcutAction/usesNumberedDigitMatching``) stands in
/// for the whole `⌃1`…`⌃9` family, so at runtime it consumes *every* digit with
/// its modifiers. It therefore conflicts with any same-modifier digit binding —
/// whether that's another numbered family or an exact `⌃5`. Mirrors the legacy
/// app-target `shortcutsConflict` family logic.
///
/// This must be checked with the *family* semantics rather than a raw
/// `ShortcutStroke` equality: the recorder normalizes a recorded numbered digit
/// to the `"1"` placeholder, so an exact-key comparison would miss a real
/// `⌃⌥5`-vs-`⌃⌥1…9` collision (the placeholder is `"1"`, the existing binding
/// is `"5"`).
///
/// - Parameters:
///   - lhs: The first stroke of one binding.
///   - lhsNumbered: Whether `lhs` belongs to a numbered-digit action.
///   - rhs: The first stroke of the other binding.
///   - rhsNumbered: Whether `rhs` belongs to a numbered-digit action.
/// - Returns: `true` when the two bindings would fire on an overlapping keystroke.
func numberedAwareStrokesConflict(
    _ lhs: ShortcutStroke,
    numbered lhsNumbered: Bool,
    _ rhs: ShortcutStroke,
    numbered rhsNumbered: Bool
) -> Bool {
    let lhsFamily = lhsNumbered && isNumberedDigitKey(lhs.key)
    let rhsFamily = rhsNumbered && isNumberedDigitKey(rhs.key)
    if lhsFamily || rhsFamily {
        // A 1…9 family consumes every digit with its modifiers, so a collision
        // requires both sides to be digit-keyed with the same modifiers. A
        // non-digit binding (e.g. ⌃⌥T) never collides with the digit family.
        guard isNumberedDigitKey(lhs.key), isNumberedDigitKey(rhs.key) else { return false }
        return sameModifiers(lhs, rhs)
    }
    // Exact match on key + modifiers, ignoring `keyCode`: the same logical
    // keystroke can be stored with or without a resolved virtual key code (e.g.
    // recorded vs. hand-written cmux.json), so a full `ShortcutStroke` equality
    // would miss those collisions.
    return lhs.key == rhs.key && sameModifiers(lhs, rhs)
}

/// Whether two complete shortcut bindings collide under the app runtime's
/// chord-prefix semantics.
func shortcutSequencesConflict(
    _ lhs: StoredShortcut,
    numbered lhsNumbered: Bool,
    _ rhs: StoredShortcut,
    numbered rhsNumbered: Bool
) -> Bool {
    guard !lhs.isUnbound, !rhs.isUnbound else { return false }

    switch (lhs.hasChord, rhs.hasChord) {
    case (false, false):
        return numberedAwareStrokesConflict(
            lhs.first,
            numbered: lhsNumbered,
            rhs.first,
            numbered: rhsNumbered
        )
    case (true, true):
        guard numberedAwareStrokesConflict(
            lhs.first,
            numbered: false,
            rhs.first,
            numbered: false
        ),
        let lhsSecond = lhs.second,
        let rhsSecond = rhs.second else {
            return false
        }
        return numberedAwareStrokesConflict(
            lhsSecond,
            numbered: lhsNumbered,
            rhsSecond,
            numbered: rhsNumbered
        )
    case (true, false):
        return numberedAwareStrokesConflict(
            lhs.first,
            numbered: false,
            rhs.first,
            numbered: rhsNumbered
        )
    case (false, true):
        return numberedAwareStrokesConflict(
            lhs.first,
            numbered: lhsNumbered,
            rhs.first,
            numbered: false
        )
    }
}

private func sameModifiers(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
    lhs.command == rhs.command
        && lhs.shift == rhs.shift
        && lhs.option == rhs.option
        && lhs.control == rhs.control
}
