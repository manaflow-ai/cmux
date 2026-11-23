/// A vim word motion: `w`, `b`, `e` over words (letters, digits and `_`,
/// or a run of other non-blank characters), `W`, `B`, `E` over WORDs
/// (any run of non-blank characters).
public enum CopyModeWordMove: String, Equatable, Sendable, CaseIterable {
    /// `w`: the start of the next word.
    case wordForward = "word_forward"
    /// `b`: the start of this or the previous word.
    case wordBackward = "word_backward"
    /// `e`: the end of this or the next word.
    case wordEnd = "word_end"
    /// `W`
    case bigWordForward = "big_word_forward"
    /// `B`
    case bigWordBackward = "big_word_backward"
    /// `E`
    case bigWordEnd = "big_word_end"

    var isBigWord: Bool {
        switch self {
        case .bigWordForward, .bigWordBackward, .bigWordEnd: true
        case .wordForward, .wordBackward, .wordEnd: false
        }
    }
}

/// Word motions over the visible rows, counted in the steps Ghostty's
/// `adjust_selection:left` and `:right` take. Those steps skip blank cells
/// and wrap rows, and a word motion always lands on a non-blank cell, so a
/// motion is the signed number of text cells between the cursor and its
/// target. A row end separates words.
public struct CopyModeWords {
    public init() {}
    /// Signed `adjust_selection` steps (positive: right) that move the
    /// cursor at `row`, `column` by `move`, `count` times. `rows` is the
    /// viewport's text, one string per row, as Ghostty reads it (a wide
    /// glyph takes two columns). Stops at the first or last text cell when
    /// the rows run out of words.
    public static func steps(rows: [String], row: Int, column: Int, move: CopyModeWordMove, count: Int) -> Int {
        let cells = textCells(rows: rows, bigWord: move.isBigWord)
        guard !cells.isEmpty else { return 0 }
        // `first`: index of the first text cell at or after the cursor.
        let first = cells.firstIndex { ($0.row, $0.column) >= (row, column) } ?? cells.count
        let onText = first < cells.count && cells[first].row == row && cells[first].column == column
        let count = CopyModeKeys.clampCount(count)

        func startsWord(_ i: Int) -> Bool {
            i == 0 || cells[i].gapBefore || cells[i].kind != cells[i - 1].kind
        }
        func endsWord(_ i: Int) -> Bool {
            i == cells.count - 1 || startsWord(i + 1)
        }

        switch move {
        case .wordForward, .bigWordForward, .wordEnd, .bigWordEnd:
            let isTarget = move == .wordEnd || move == .bigWordEnd ? endsWord : startsWord
            // The cursor's own index; a cursor on a blank sits just before `first`.
            var position = onText ? first : first - 1
            for _ in 0..<count {
                guard let next = ((position + 1)..<cells.count).first(where: isTarget) else {
                    position = cells.count - 1
                    break
                }
                position = next
            }
            return max(0, position - first + (onText ? 0 : 1))
        case .wordBackward, .bigWordBackward:
            var position = first
            for _ in 0..<count {
                guard position > 0, let previous = (0..<position).last(where: startsWord) else {
                    position = 0
                    break
                }
                position = previous
            }
            return -max(0, first - position)
        }
    }

    /// Display columns of one character: 2 for a wide (East Asian wide or
    /// fullwidth, or emoji-presentation) glyph, else 1.
    public static func cellWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    // MARK: Cells

    enum Kind: Equatable { case word, punctuation }

    struct TextCell {
        let row: Int
        let column: Int
        let kind: Kind
        /// A blank cell or a row end lies between this cell and the text cell before it.
        let gapBefore: Bool
    }

    /// The non-blank cells of `rows` in reading order.
    static func textCells(rows: [String], bigWord: Bool) -> [TextCell] {
        var cells: [TextCell] = []
        for (row, text) in rows.enumerated() {
            var column = 0
            var gap = true
            for character in text {
                if character.isWhitespace {
                    gap = true
                } else {
                    let kind: Kind = bigWord || character.isLetter || character.isNumber || character == "_"
                        ? .word : .punctuation
                    cells.append(TextCell(row: row, column: column, kind: kind, gapBefore: gap))
                    gap = false
                }
                column += cellWidth(character)
            }
        }
        return cells
    }
}
