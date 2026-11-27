/// Copy Mode (the Mac's Toggle Copy Mode, Shift-Cmd-M): a cursor over the terminal's rows,
/// scrollback included, moved with vi keys from a hardware keyboard, and a visual
/// selection that `y` copies. The phone's touch selection draws it (`TerminalTextSelection`),
/// so the handles still move either end.
///
/// Keys: h j k l (and the arrows) move one cell or row; w and b move to the next or
/// previous word start, across rows; 0 and $ go to the row's start and its last
/// character; g and G go to the first and the last row; v starts or ends the visual
/// selection; y copies it (with none, the cursor's row) and leaves; Escape leaves.
public struct TerminalCopyMode: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case left, down, up, right
        case wordForward, wordBackward
        case lineStart, lineEnd
        case top, bottom
        case toggleVisual, yank, exit
    }

    /// What a key did.
    public enum Outcome: Equatable, Sendable {
        /// The cursor or the selection changed (or stayed at an edge).
        case moved
        /// Copy these cells (both inclusive), then leave Copy Mode.
        case copy(from: TerminalCellPoint, to: TerminalCellPoint)
        case exit
    }

    public var cursor: TerminalCellPoint
    /// The visual selection's fixed end (nil: no selection, only the cursor).
    public var mark: TerminalCellPoint?

    public init(cursor: TerminalCellPoint, mark: TerminalCellPoint? = nil) {
        self.cursor = cursor
        self.mark = mark
    }

    public var isVisual: Bool { mark != nil }

    /// What the touch selection draws: the selection, or the cursor's cell.
    public var selection: TerminalTextSelection {
        TerminalTextSelection(anchor: mark ?? cursor, head: cursor)
    }

    /// The key a hardware key press names: its characters (`$` and `G` with Shift) or the
    /// arrows and Escape by their HID usage. Nil for any other key, which Copy Mode ignores.
    public static func key(characters: String, usage: UInt16) -> Key? {
        switch usage {
        case 0x29: return .exit // Escape
        case 0x50: return .left
        case 0x4F: return .right
        case 0x51: return .down
        case 0x52: return .up
        default: break
        }
        switch characters {
        case "h": return .left
        case "j": return .down
        case "k": return .up
        case "l": return .right
        case "w": return .wordForward
        case "b": return .wordBackward
        case "0": return .lineStart
        case "$": return .lineEnd
        case "g": return .top
        case "G": return .bottom
        case "v": return .toggleVisual
        case "y": return .yank
        default: return nil
        }
    }

    /// Applies `key` over `rows` (the document's rows, first to one past the last) of
    /// `columns` cells; `line` reads a row's text, one character per cell.
    public mutating func apply(_ key: Key, rows: Range<Int>, columns: Int, line: (Int) -> String) -> Outcome {
        guard !rows.isEmpty else { return key == .exit ? .exit : .moved }
        let lastColumn = max(0, columns - 1)
        cursor.row = min(max(cursor.row, rows.lowerBound), rows.upperBound - 1)
        cursor.column = min(max(cursor.column, 0), lastColumn)
        switch key {
        case .left:
            cursor.column = max(0, cursor.column - 1)
        case .right:
            cursor.column = min(lastColumn, cursor.column + 1)
        case .up:
            cursor.row = max(rows.lowerBound, cursor.row - 1)
        case .down:
            cursor.row = min(rows.upperBound - 1, cursor.row + 1)
        case .lineStart:
            cursor.column = 0
        case .lineEnd:
            cursor.column = min(lastColumn, max(0, Self.lastCharacter(in: line(cursor.row))))
        case .top:
            cursor = TerminalCellPoint(row: rows.lowerBound, column: 0)
        case .bottom:
            cursor = TerminalCellPoint(row: rows.upperBound - 1, column: 0)
        case .wordForward:
            cursor = Self.nextWordStart(after: cursor, rows: rows, lastColumn: lastColumn, line: line)
        case .wordBackward:
            cursor = Self.previousWordStart(before: cursor, rows: rows, lastColumn: lastColumn, line: line)
        case .toggleVisual:
            mark = mark == nil ? cursor : nil
        case .yank:
            if let mark { return .copy(from: min(mark, cursor), to: max(mark, cursor)) }
            return .copy(from: TerminalCellPoint(row: cursor.row, column: 0), to: TerminalCellPoint(row: cursor.row, column: lastColumn))
        case .exit:
            return .exit
        }
        return .moved
    }

    /// The last non-blank character's column, or -1 for a blank row.
    static func lastCharacter(in line: String) -> Int {
        let characters = Array(line)
        var index = characters.count - 1
        while index >= 0, characters[index] == " " { index -= 1 }
        return index
    }

    /// vi's character classes: blanks, word characters, everything else.
    enum CharacterClass { case blank, word, punctuation }

    static func characterClass(_ character: Character?) -> CharacterClass {
        guard let character, character != " ", character != "\t" else { return .blank }
        return character.isLetter || character.isNumber || character == "_" ? .word : .punctuation
    }

    /// Every cell from `start` on, row by row (a row end counts as a blank between rows).
    private static func cells(from start: TerminalCellPoint, forward: Bool, rows: Range<Int>, lastColumn: Int,
                              line: (Int) -> String) -> [(TerminalCellPoint, CharacterClass)] {
        var out: [(TerminalCellPoint, CharacterClass)] = []
        var row = start.row
        var first = true
        while rows.contains(row) {
            let characters = Array(line(row))
            let columns = Array(0...lastColumn)
            let ordered = forward ? columns : columns.reversed()
            for column in ordered {
                if first, forward ? column < start.column : column > start.column { continue }
                let character = column < characters.count ? characters[column] : nil
                out.append((TerminalCellPoint(row: row, column: column), characterClass(character)))
            }
            first = false
            row += forward ? 1 : -1
            // Limit the walk: a word start is never more than a few hundred rows away in practice.
            if out.count > 64 * (lastColumn + 1) { break }
        }
        return out
    }

    /// vi's `w`: the next cell that starts a word (a class change into a non-blank, or
    /// the first non-blank of a later row). Stays put when there is none.
    static func nextWordStart(after cursor: TerminalCellPoint, rows: Range<Int>, lastColumn: Int,
                              line: (Int) -> String) -> TerminalCellPoint {
        let walk = cells(from: cursor, forward: true, rows: rows, lastColumn: lastColumn, line: line)
        guard var previous = walk.first?.1 else { return cursor }
        var previousRow = cursor.row
        for (cell, kind) in walk.dropFirst() {
            // A new row starts a new word even right after a word character.
            if cell.row != previousRow { previous = .blank; previousRow = cell.row }
            if kind != .blank, kind != previous { return cell }
            previous = kind
        }
        return cursor
    }

    /// vi's `b`: the start of the word before the cursor (or of the word it is inside).
    static func previousWordStart(before cursor: TerminalCellPoint, rows: Range<Int>, lastColumn: Int,
                                  line: (Int) -> String) -> TerminalCellPoint {
        let walk = cells(from: cursor, forward: false, rows: rows, lastColumn: lastColumn, line: line)
        // Skip the cursor's own cell, then any blanks; then the run of one class.
        var index = 1
        while index < walk.count, walk[index].1 == .blank { index += 1 }
        guard index < walk.count else { return cursor }
        let kind = walk[index].1
        var start = walk[index].0
        index += 1
        while index < walk.count, walk[index].1 == kind, walk[index].0.row == start.row {
            start = walk[index].0
            index += 1
        }
        return start
    }
}
