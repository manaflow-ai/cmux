/// The vim word motion behind a word ``TerminalKeyboardCopyModeSelectionMove``.
///
/// Copy mode works on one terminal row at a time. A row is the list of glyphs
/// Ghostty prints for it: one `Character` per non-spacer cell, so a wide glyph
/// is one entry and an empty cell between glyphs is a space. Rows end at their
/// last glyph, so an all-empty row is an empty list.
///
/// ```swift
/// let motion = TerminalKeyboardCopyModeWordMotion(.wordForward)
/// let target = motion?.resolve(
///     count: 1,
///     line: Array("echo hello"),
///     index: 0,
///     adjacentLine: { _ in nil }
/// )
/// // target == 5
/// ```
///
/// Classes follow vim's defaults: letters, digits and `_` form words, other
/// non-blank glyphs form punctuation runs, and whitespace separates both. The
/// big-word variants (`W`, `B`, `E`) treat every non-blank glyph as one class.
/// An all-empty row is a stop for `w` and `b`, as an empty line is in vim.
public struct TerminalKeyboardCopyModeWordMotion: Equatable, Sendable {
    /// Where a word motion lands.
    public enum Target: Equatable, Sendable {
        /// The first glyph of the next word (`w`, `W`).
        case nextWordStart

        /// The first glyph of the current or previous word (`b`, `B`).
        case previousWordStart

        /// The last glyph of the current or next word (`e`, `E`).
        case nextWordEnd
    }

    /// Where the motion lands.
    public var target: Target

    /// Whether every non-blank glyph counts as a word character.
    public var bigWord: Bool

    /// Creates a word motion.
    ///
    /// - Parameters:
    ///   - target: Where the motion lands.
    ///   - bigWord: Whether every non-blank glyph counts as a word character.
    public init(target: Target, bigWord: Bool) {
        self.target = target
        self.bigWord = bigWord
    }

    /// Creates the word motion for a selection move, or `nil` for a move that
    /// does not depend on the row text.
    ///
    /// - Parameter move: The copy-mode move.
    public init?(_ move: TerminalKeyboardCopyModeSelectionMove) {
        switch move {
        case .wordForward:
            self.init(target: .nextWordStart, bigWord: false)
        case .wordBackward:
            self.init(target: .previousWordStart, bigWord: false)
        case .wordEndForward:
            self.init(target: .nextWordEnd, bigWord: false)
        case .bigWordForward:
            self.init(target: .nextWordStart, bigWord: true)
        case .bigWordBackward:
            self.init(target: .previousWordStart, bigWord: true)
        case .bigWordEndForward:
            self.init(target: .nextWordEnd, bigWord: true)
        case .left, .right, .up, .down, .pageUp, .pageDown, .home, .end,
             .beginningOfLine, .endOfLine:
            return nil
        }
    }

    /// Applies the motion `count` times and returns the landing glyph index.
    ///
    /// When the motion runs off the current row it calls `adjacentLine` with
    /// `true` for the next row or `false` for the previous one. The closure
    /// moves the host's cursor to that row and returns its glyphs, or returns
    /// `nil` at the edge of the scrollback without moving. The returned index
    /// is on the row the closure last moved to, or on `line` when it never
    /// moved.
    ///
    /// - Parameters:
    ///   - count: The repeat count; values below one act as one.
    ///   - line: The glyphs of the cursor's row.
    ///   - index: The cursor's glyph index in `line`. An index at or past the
    ///     end means the cursor is in the empty cells after the last glyph.
    ///   - adjacentLine: Moves to the next (`true`) or previous (`false`) row
    ///     and returns its glyphs, or returns `nil` at the scrollback edge.
    /// - Returns: The glyph index to move the cursor to.
    public func resolve(
        count: Int,
        line: [Character],
        index: Int,
        adjacentLine: (_ forward: Bool) -> [Character]?
    ) -> Int {
        var scanner = Scanner(line: line, index: max(index, 0), bigWord: bigWord)
        for _ in 0 ..< terminalKeyboardCopyModeClampCount(count) {
            let reachedEdge: Bool
            switch target {
            case .nextWordStart:
                reachedEdge = scanner.moveToNextWordStart(adjacentLine)
            case .previousWordStart:
                reachedEdge = scanner.moveToPreviousWordStart(adjacentLine)
            case .nextWordEnd:
                reachedEdge = scanner.moveToNextWordEnd(adjacentLine)
            }
            if reachedEdge { break }
        }
        return scanner.index
    }
}

/// The class vim word motions use to group glyphs.
public enum TerminalKeyboardCopyModeWordCharacterClass: Equatable, Sendable {
    /// Whitespace, including the spaces Ghostty prints for empty cells.
    case blank

    /// Non-blank glyphs that are not word characters.
    case punctuation

    /// Letters, digits and `_`, or any non-blank glyph for big words.
    case word

    /// Classifies a glyph.
    ///
    /// - Parameters:
    ///   - character: The glyph to classify.
    ///   - bigWord: Whether every non-blank glyph counts as a word character.
    public init(_ character: Character, bigWord: Bool) {
        if character.isWhitespace || character == "\u{0}" {
            self = .blank
        } else if bigWord || character == "_" || character.isLetter || character.isNumber {
            self = .word
        } else {
            self = .punctuation
        }
    }
}

private struct Scanner {
    var line: [Character]
    var index: Int
    let bigWord: Bool

    private func characterClass(at position: Int) -> TerminalKeyboardCopyModeWordCharacterClass {
        guard position >= 0, position < line.count else { return .blank }
        return TerminalKeyboardCopyModeWordCharacterClass(line[position], bigWord: bigWord)
    }

    private var lastIndex: Int { max(line.count - 1, 0) }

    /// Where a forward motion stops when the scrollback ends: the last glyph,
    /// as in vim, but never left of a cursor that started past it on this row.
    private func forwardEdgeIndex(crossedRows: Bool) -> Int {
        crossedRows ? lastIndex : max(index, lastIndex)
    }

    /// vim `w`. Returns `true` when the scrollback ended before a word start.
    mutating func moveToNextWordStart(
        _ adjacentLine: (_ forward: Bool) -> [Character]?
    ) -> Bool {
        var position = min(index, line.count)
        let startClass = characterClass(at: position)
        if startClass != .blank {
            while position < line.count, characterClass(at: position) == startClass {
                position += 1
            }
        }
        while position < line.count, characterClass(at: position) == .blank {
            position += 1
        }
        if position < line.count {
            index = position
            return false
        }

        var crossedRows = false
        while let next = adjacentLine(true) {
            crossedRows = true
            line = next
            if line.isEmpty {
                index = 0
                return false
            }
            position = 0
            while position < line.count, characterClass(at: position) == .blank {
                position += 1
            }
            if position < line.count {
                index = position
                return false
            }
        }
        index = forwardEdgeIndex(crossedRows: crossedRows)
        return true
    }

    /// vim `b`. Returns `true` when the scrollback ended before a word start.
    mutating func moveToPreviousWordStart(
        _ adjacentLine: (_ forward: Bool) -> [Character]?
    ) -> Bool {
        var position = min(index, line.count) - 1
        while true {
            while position >= 0, characterClass(at: position) == .blank {
                position -= 1
            }
            if position >= 0 { break }
            guard let previous = adjacentLine(false) else {
                index = 0
                return true
            }
            line = previous
            if line.isEmpty {
                index = 0
                return false
            }
            position = line.count - 1
        }
        let wordClass = characterClass(at: position)
        while position > 0, characterClass(at: position - 1) == wordClass {
            position -= 1
        }
        index = position
        return false
    }

    /// vim `e`. Returns `true` when the scrollback ended before a word end.
    mutating func moveToNextWordEnd(
        _ adjacentLine: (_ forward: Bool) -> [Character]?
    ) -> Bool {
        var position = index + 1
        var crossedRows = false
        while true {
            while position < line.count, characterClass(at: position) == .blank {
                position += 1
            }
            if position < line.count { break }
            guard let next = adjacentLine(true) else {
                index = forwardEdgeIndex(crossedRows: crossedRows)
                return true
            }
            crossedRows = true
            line = next
            position = 0
        }
        let wordClass = characterClass(at: position)
        while position + 1 < line.count, characterClass(at: position + 1) == wordClass {
            position += 1
        }
        index = position
        return false
    }
}
