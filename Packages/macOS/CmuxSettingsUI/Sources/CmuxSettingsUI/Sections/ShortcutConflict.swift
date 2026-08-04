import CmuxSettings

/// Whether two shortcut first-strokes collide, accounting for numbered-digit
/// families.
///
/// A numbered binding (``ShortcutAction/numberedDigitRange``) stands in for an
/// action-specific digit range. It conflicts with same-modifier exact digits
/// inside that range and with another numbered family whose range overlaps.
///
/// This must be checked with the *family* semantics rather than a raw
/// `ShortcutStroke` equality: the recorder normalizes a recorded numbered digit
/// to the `"1"` placeholder, so an exact-key comparison would miss a real
/// `⌃⌥5`-vs-`⌃⌥1…9` collision (the placeholder is `"1"`, the existing binding
/// is `"5"`).
///
/// - Parameters:
///   - lhs: The first stroke of one binding.
///   - lhsNumberedRange: The numbered range consumed by `lhs`, if any.
///   - rhs: The first stroke of the other binding.
///   - rhsNumberedRange: The numbered range consumed by `rhs`, if any.
/// - Returns: `true` when the two bindings would fire on an overlapping keystroke.
func numberedAwareStrokesConflict(
    _ lhs: ShortcutStroke,
    numberedRange lhsNumberedRange: ClosedRange<Int>?,
    _ rhs: ShortcutStroke,
    numberedRange rhsNumberedRange: ClosedRange<Int>?
) -> Bool {
    let lhs = lhs.canonicalized()
    let rhs = rhs.canonicalized()
    guard sameModifiers(lhs, rhs) else { return false }

    let lhsDigit = Int(lhs.key)
    let rhsDigit = Int(rhs.key)
    let lhsFamily = lhsNumberedRange.flatMap { range in
        lhsDigit.map(range.contains) == true ? range : nil
    }
    let rhsFamily = rhsNumberedRange.flatMap { range in
        rhsDigit.map(range.contains) == true ? range : nil
    }
    switch (lhsFamily, rhsFamily) {
    case let (lhsRange?, rhsRange?):
        return lhsRange.overlaps(rhsRange)
    case let (lhsRange?, nil):
        return rhsDigit.map(lhsRange.contains) == true
    case let (nil, rhsRange?):
        return lhsDigit.map(rhsRange.contains) == true
    case (nil, nil):
        return lhs.key == rhs.key
    }
}

private func sameModifiers(_ lhs: ShortcutStroke, _ rhs: ShortcutStroke) -> Bool {
    lhs.command == rhs.command
        && lhs.shift == rhs.shift
        && lhs.option == rhs.option
        && lhs.control == rhs.control
}
