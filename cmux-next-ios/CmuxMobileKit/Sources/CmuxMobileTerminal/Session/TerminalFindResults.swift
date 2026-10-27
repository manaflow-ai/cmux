import Foundation

/// The matches of a find in the terminal's rows (the Mac's Find…, `TerminalFindController`):
/// case-insensitive, like Ghostty's search, across soft-wrapped rows, in document order
/// (oldest row first). The first match shown is the newest (nearest the prompt), as on
/// the Mac; Next and Previous step through them and wrap.
///
/// ```swift
/// var find = TerminalFindResults(rows: rows, wraps: wraps, firstRow: 0, columns: 80, query: "error")
/// find.selected        // the newest match
/// find.step(forward: false)  // the one above it
/// ```
public struct TerminalFindResults: Equatable, Sendable {
    /// One match: its cells on each row it covers (`end` inclusive).
    public struct Match: Equatable, Sendable {
        public var segments: [TerminalLink.Segment]
        /// The first row the match covers.
        public var row: Int { segments.first?.row ?? 0 }
    }

    /// At most this many matches are kept (a one-letter query in a long scrollback).
    public static let limit = 10_000

    public private(set) var query: String
    public private(set) var matches: [Match]
    /// The index of the highlighted match in `matches`, nil when there are none.
    public private(set) var selected: Int?

    /// No search.
    public init() {
        query = ""
        matches = []
        selected = nil
    }

    /// Searches `rows` (row `firstRow + i` is `rows[i]`; `wraps[i]`: it goes on, soft
    /// wrapped, on the next row) for `query`.
    public init(rows: [String], wraps: [Bool], firstRow: Int, columns: Int, query: String) {
        self.query = query
        matches = Self.search(rows: rows, wraps: wraps, firstRow: firstRow, columns: columns, query: query)
        selected = matches.isEmpty ? nil : matches.count - 1
    }

    /// What the find bar's count shows: the selected match's 1-based position.
    public var position: Int? { selected.map { $0 + 1 } }

    /// The highlighted match.
    public var selectedMatch: Match? { selected.map { matches[$0] } }

    /// Next (`forward`, down toward the prompt) or Previous (up into the scrollback), wrapping.
    public mutating func step(forward: Bool) {
        guard !matches.isEmpty else { return }
        let current = selected ?? (forward ? -1 : matches.count)
        selected = (current + (forward ? 1 : -1) + matches.count) % matches.count
    }

    /// Ghostty dropped `rows` of its oldest rows (or numbered them again): the
    /// matches keep their text; those that left the history go.
    public mutating func shiftRows(by delta: Int) {
        guard delta != 0, !matches.isEmpty else { return }
        var kept: [Match] = []
        var newSelected: Int?
        for (index, match) in matches.enumerated() {
            let segments = match.segments.map { TerminalLink.Segment(row: $0.row + delta, start: $0.start, end: $0.end) }
            guard !segments.contains(where: { $0.row < 0 }) else { continue }
            if index == selected { newSelected = kept.count }
            kept.append(Match(segments: segments))
        }
        matches = kept
        selected = kept.isEmpty ? nil : (newSelected ?? 0)
    }

    /// The match nearest `row` becomes the selected one (a search again after new
    /// output keeps the place the person was at).
    public mutating func select(nearestRow row: Int) {
        guard !matches.isEmpty else { return }
        var best = 0
        for (index, match) in matches.enumerated() where abs(match.row - row) <= abs(matches[best].row - row) { best = index }
        selected = best
    }

    /// The matches whose rows meet `rows`, with their indices.
    public func matches(in rows: Range<Int>) -> [(index: Int, match: Match)] {
        guard !matches.isEmpty, !rows.isEmpty else { return [] }
        // Matches are in row order: start at the first that can reach `rows`.
        var low = 0, high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if (matches[mid].segments.last?.row ?? 0) < rows.lowerBound { low = mid + 1 } else { high = mid }
        }
        var out: [(index: Int, match: Match)] = []
        var index = low
        while index < matches.count, matches[index].row < rows.upperBound {
            out.append((index: index, match: matches[index]))
            index += 1
        }
        return out
    }

    // MARK: Search

    private static func search(rows: [String], wraps: [Bool], firstRow: Int, columns: Int, query: String) -> [Match] {
        guard !query.isEmpty, !rows.isEmpty else { return [] }
        var found: [Match] = []
        var start = 0
        while start < rows.count, found.count < limit {
            // One logical line: the rows soft-wrapped into each other.
            var end = start
            while end < rows.count - 1, end < wraps.count, wraps[end] { end += 1 }
            searchLine(rows: rows[start...end], firstIndex: start, firstRow: firstRow, columns: columns, query: query, into: &found)
            start = end + 1
        }
        return found
    }

    private static func searchLine(rows: ArraySlice<String>, firstIndex: Int, firstRow: Int, columns: Int, query: String,
                                   into found: inout [Match]) {
        let line = rows.joined()
        guard line.range(of: query, options: .caseInsensitive) != nil else { return }
        // Cells of each character of the line: its row and column.
        var cells: [(row: Int, start: Int, end: Int)] = []
        for (offset, text) in rows.enumerated() {
            let row = TerminalCellRow(text, columns: columns)
            for index in row.characters.indices {
                cells.append((firstRow + firstIndex + offset, row.starts[index], row.starts[index] + row.widths[index] - 1))
            }
        }
        var from = line.startIndex
        var fromOffset = 0
        while from < line.endIndex, found.count < limit,
              let range = line.range(of: query, options: .caseInsensitive, range: from..<line.endIndex) {
            let lower = fromOffset + line.distance(from: from, to: range.lowerBound)
            let upper = lower + line.distance(from: range.lowerBound, to: range.upperBound)
            from = range.upperBound
            fromOffset = upper
            guard lower < upper, upper <= cells.count else { continue }
            var segments: [TerminalLink.Segment] = []
            for cell in cells[lower..<upper] {
                if var last = segments.last, last.row == cell.row {
                    last.end = cell.end
                    segments[segments.count - 1] = last
                } else {
                    segments.append(TerminalLink.Segment(row: cell.row, start: cell.start, end: cell.end))
                }
            }
            found.append(Match(segments: segments))
        }
    }
}
