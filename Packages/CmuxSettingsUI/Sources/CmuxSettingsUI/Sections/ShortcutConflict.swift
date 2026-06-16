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

private func sameModifiers(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
    lhs.command == rhs.command
        && lhs.shift == rhs.shift
        && lhs.option == rhs.option
        && lhs.control == rhs.control
}

/// Expands a configured legacy ``ShortcutAction/selectSurfaceByNumber`` binding
/// onto the per-surface digit `action` targets, mirroring the app target's
/// `KeyboardShortcutSettingsLookup` runtime derivation so the settings UI shows
/// and conflict-checks the same shortcut the app actually routes.
///
/// - Returns: `nil` for non-surface actions or when `legacyBinding` is `nil` (no
///   legacy entry configured), so the caller falls through to the action's own
///   binding or built-in default. Returns ``StoredShortcut/unbound`` when the
///   legacy family is explicitly unbound, so a user who disabled surface
///   selection through the legacy action keeps every per-surface shortcut
///   disabled instead of resurrecting the ⌃-digit defaults.
func legacySurfaceSelectionShortcut(
    for action: ShortcutAction,
    legacyBinding: StoredShortcut?
) -> StoredShortcut? {
    guard let digit = action.surfaceSelectionDigit, let legacy = legacyBinding else {
        return nil
    }
    guard !legacy.isUnbound else { return .unbound }
    let digitKey = String(digit)
    // Preserve the legacy modifiers and stroke shape: a chord replaces the
    // second-stroke digit, a single stroke replaces the primary key.
    if let second = legacy.second {
        return StoredShortcut(first: legacy.first, second: second.replacingKey(digitKey))
    }
    return StoredShortcut(first: legacy.first.replacingKey(digitKey))
}

/// The shortcut the app target would route for `action`, mirroring
/// `KeyboardShortcutSettingsLookup.shortcutIfBound`: an explicit `bindings`
/// entry wins (even when unbound), otherwise a configured legacy
/// `selectSurfaceByNumber` binding is expanded onto the matching per-surface
/// digit, otherwise the action's built-in default. The settings UI resolves row
/// display and conflict detection through this so it never diverges from runtime
/// routing for migrated surface bindings.
func effectiveStoredShortcut(
    for action: ShortcutAction,
    bindings: [String: StoredShortcut]
) -> StoredShortcut? {
    if let override = bindings[action.rawValue] {
        return override
    }
    if let legacy = legacySurfaceSelectionShortcut(
        for: action,
        legacyBinding: bindings[ShortcutAction.selectSurfaceByNumber.rawValue]
    ) {
        return legacy
    }
    return action.defaultShortcut
}

/// The action's effective focus predicate: its `shortcuts.when` override if
/// present, otherwise an inherited legacy `selectSurfaceByNumber` predicate for
/// per-surface actions (so a user who scoped only the legacy family keeps that
/// predicate after the split into per-surface actions), otherwise its built-in
/// ``ShortcutAction/defaultFocusWhenClause``. Mirrors the app target's
/// `KeyboardShortcutSettingsLookup.effectiveWhenClause` so conflict detection
/// evaluates the same context the runtime does.
func effectiveWhenClause(
    for action: ShortcutAction,
    whenOverrideClauses: [String: ShortcutWhenClause]
) -> ShortcutWhenClause {
    if let clause = whenOverrideClauses[action.rawValue] {
        return clause
    }
    if action.surfaceSelectionDigit != nil,
       let legacyClause = whenOverrideClauses[ShortcutAction.selectSurfaceByNumber.rawValue] {
        return legacyClause
    }
    return action.defaultFocusWhenClause
}

private extension ShortcutStroke {
    /// A copy of this stroke with its `key` replaced, preserving modifiers. The
    /// virtual `keyCode` is dropped because it described the original physical
    /// key, not the substituted digit; conflict detection and display compare
    /// `key` + modifiers only (see ``numberedAwareStrokesConflict``).
    func replacingKey(_ newKey: String) -> ShortcutStroke {
        ShortcutStroke(
            key: newKey,
            command: command,
            shift: shift,
            option: option,
            control: control,
            keyCode: nil
        )
    }
}
