import Foundation

/// The last thing the person sent from the phone (a composer send, a voice
/// prompt), for the terminal's top strip: one tap there scrolls back to it
/// (Leo, 2026-11-23: "i want to be able to click (tap) the top bit of the
/// terminal in phone to jump to that last sent bit").
///
/// Two clues find it again: the row the cursor was on when it went (moved
/// with every prune, as the find's matches are), and its text. The text wins
/// when it is still in the rows, since a program can echo the prompt
/// somewhere else than the cursor was (an agent CLI's input box clears and
/// the prompt appears in its transcript); the row is the fallback.
public struct TerminalLastSent: Equatable, Sendable {
    /// The text as the strip shows it: the first line with text, whitespace collapsed.
    public let preview: String
    /// The absolute row (the scrollbar's numbering) the cursor was on when it went.
    public private(set) var row: Int?

    /// The characters of the preview a row is searched for: enough to tell
    /// prompts apart, few enough that a prompt marker plus them fits one row
    /// of a narrow phone grid before it wraps.
    static let needleLength = 32

    /// Nil for a send with no text (a bare Return keeps the last one).
    public init?(text: String, row: Int?) {
        let line = text.split(whereSeparator: \.isNewline)
            .map(Self.collapsed)
            .first { !$0.isEmpty }
        guard let line else { return nil }
        preview = line
        self.row = row.map { max(0, $0) }
    }

    /// Ghostty pruned or renumbered rows: the row moves with them. A row
    /// pruned away is gone (only the text can find it then).
    public mutating func shiftRows(by delta: Int) {
        guard let row else { return }
        let moved = row + delta
        self.row = moved >= 0 ? moved : nil
    }

    /// The row found when the strip was tapped: later finds start from it.
    public mutating func found(at row: Int) {
        self.row = row
    }

    /// The row that shows the sent text in `rows` (`rows[i]` is row
    /// `firstRow + i`): the last row containing it, the one nearest the
    /// recorded row when several do (the same prompt sent twice: the newer
    /// send recorded the newer row). Else the recorded row, when it is in
    /// `rows`. Nil when neither is.
    public func locate(in rows: [String], firstRow: Int = 0) -> Int? {
        let needle = String(preview.prefix(Self.needleLength))
        var matches: [Int] = []
        for (i, text) in rows.enumerated() where Self.collapsed(text).contains(needle) {
            matches.append(firstRow + i)
        }
        let range = firstRow..<(firstRow + rows.count)
        if let row, !matches.isEmpty {
            // Nearest the recorded row, ties to the newer (lower) row.
            return matches.min { abs($0 - row) < abs($1 - row) || (abs($0 - row) == abs($1 - row) && $0 > $1) }
        }
        if let last = matches.last { return last }
        if let row, range.contains(row) { return row }
        return nil
    }

    /// Whether the strip shows: there is a row to go to and it is not among
    /// the rows on screen.
    public static func stripShows(row: Int?, visibleRows: Range<Int>, isTUI: Bool) -> Bool {
        guard !isTUI, let row else { return false }
        return !visibleRows.contains(row)
    }

    static func collapsed<S: StringProtocol>(_ text: S) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
