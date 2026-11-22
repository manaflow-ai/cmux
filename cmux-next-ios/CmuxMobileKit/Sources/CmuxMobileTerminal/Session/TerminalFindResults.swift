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

    /// Matches in document order. Lines are searched newest first, so past `limit` the
    /// matches kept are the newest (nearest the prompt), as the selected one is.
    private static func search(rows: [String], wraps: [Bool], firstRow: Int, columns: Int, query: String) -> [Match] {
        let needle = query.map { Self.folded($0) }
        guard !needle.isEmpty, !rows.isEmpty else { return [] }
        // Logical lines: the rows soft-wrapped into each other.
        var lines: [ClosedRange<Int>] = []
        var start = 0
        while start < rows.count {
            var end = start
            while end < rows.count - 1, end < wraps.count, wraps[end] { end += 1 }
            lines.append(start...end)
            start = end + 1
        }
        var newestFirst: [[Match]] = []
        var count = 0
        for line in lines.reversed() where count < limit {
            var found = searchLine(rows: rows, line: line, firstRow: firstRow, columns: columns, needle: needle)
            if count + found.count > limit { found = Array(found.suffix(limit - count)) }
            count += found.count
            if !found.isEmpty { newestFirst.append(found) }
        }
        return newestFirst.reversed().flatMap { $0 }
    }

    /// One character compared without case (Ghostty's search is case-insensitive).
    private static func folded(_ character: Character) -> String {
        String(character).lowercased()
    }

    /// The matches in one logical line. The line is the rows' characters in order, each
    /// with its own cells: no joining (a join can merge graphemes across a wrap and shift
    /// every cell after it), and every match is at least one character long.
    private static func searchLine(rows: [String], line: ClosedRange<Int>, firstRow: Int, columns: Int,
                                   needle: [String]) -> [Match] {
        var characters: [String] = []
        var cells: [(row: Int, start: Int, end: Int)] = []
        for index in line {
            let row = TerminalCellRow(rows[index], columns: columns)
            for (offset, character) in row.characters.enumerated() {
                characters.append(folded(character))
                cells.append((firstRow + index, row.starts[offset], row.starts[offset] + row.widths[offset] - 1))
            }
        }
        guard characters.count >= needle.count else { return [] }
        var found: [Match] = []
        var lower = 0
        while lower + needle.count <= characters.count {
            var hit = true
            for (k, want) in needle.enumerated() where characters[lower + k] != want {
                hit = false
                break
            }
            guard hit else {
                lower += 1
                continue
            }
            var segments: [TerminalLink.Segment] = []
            for cell in cells[lower..<(lower + needle.count)] {
                if var last = segments.last, last.row == cell.row {
                    last.end = cell.end
                    segments[segments.count - 1] = last
                } else {
                    segments.append(TerminalLink.Segment(row: cell.row, start: cell.start, end: cell.end))
                }
            }
            found.append(Match(segments: segments))
            lower += needle.count
        }
        return found
    }
}
