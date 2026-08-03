import Foundation

extension Substring {
    /// Locale-independent terminal columns used by the wrap heuristic.
    ///
    /// Swift's `count` measures grapheme clusters, not terminal cells.
    /// Full-width scripts and emoji occupy two cells, while combining-only and
    /// default-ignorable clusters occupy none. East Asian Ambiguous characters
    /// remain narrow, matching Ghostty's default width behavior.
    var visibleLength: Int {
        terminalCellColumns(in: self)
    }
}

private func terminalCellColumns(in text: Substring) -> Int {
    text.reduce(into: 0) { width, character in
        width += terminalCellColumns(in: character)
    }
}

private func terminalCellColumns(in character: Character) -> Int {
    let scalars = character.unicodeScalars
    guard let first = scalars.first else { return 0 }

    // Keep the package's existing tab convention. Exact tab expansion
    // depends on the starting column, which is unavailable at this layer.
    if first.value == 0x09 { return 1 }
    if isZeroWidth(first) { return 0 }

    // Emoji variation selectors override a base character's default
    // presentation. Other emoji sequences are one wide grapheme cell.
    if scalars.contains(where: { $0.value == 0xFE0E }) { return 1 }
    if scalars.contains(where: { $0.value == 0xFE0F })
        || scalars.contains(where: { $0.properties.isEmojiPresentation }) {
        return 2
    }

    return isEastAsianWide(first.value) ? 2 : 1
}

private func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .control, .format, .nonspacingMark, .enclosingMark:
        return true
    default:
        return false
    }
}

/// Compact coverage of Unicode East Asian Width `W`/`F` ranges. Emoji
/// presentation is handled separately so text-default symbols stay narrow.
private func isEastAsianWide(_ value: UInt32) -> Bool {
    switch value {
    case 0x1100...0x115F,
         0x2329...0x232A,
         0x2E80...0xA4CF,
         0xA960...0xA97C,
         0xAC00...0xD7A3,
         0xD7B0...0xD7FB,
         0xF900...0xFAFF,
         0xFE10...0xFE19,
         0xFE30...0xFE6F,
         0xFF01...0xFF60,
         0xFFE0...0xFFE6,
         0x16FE0...0x16FF1,
         0x17000...0x18DFF,
         0x1AFF0...0x1B2FF,
         0x1F200...0x1F251,
         0x20000...0x3FFFD:
        return value != 0x303F
    default:
        return false
    }
}
