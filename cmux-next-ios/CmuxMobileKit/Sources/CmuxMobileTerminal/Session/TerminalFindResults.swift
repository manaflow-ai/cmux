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
        /// Where the daemon found it (a `terminal-find` match), in the daemon's rows.
        public var daemon: Daemon?
        /// The first row the match covers; -1 for a daemon match older than the mirror.
        public var row: Int { segments.first?.row ?? -1 }
        /// The mirror holds the match's first row.
        public var isLoaded: Bool { !segments.isEmpty }

        public init(segments: [TerminalLink.Segment], daemon: Daemon? = nil) {
            self.segments = segments
            self.daemon = daemon
        }

        /// A daemon match's place: its first row (the daemon's numbering), the rows it spans
        /// beyond the first, and its first and last cells' columns.
        public struct Daemon: Equatable, Sendable {
            public var row: Int
            public var span: Int
            public var startColumn: Int
            public var endColumn: Int
        }
    }

    /// The matches came from the daemon (the whole history), not from the mirror's rows.
    public private(set) var fromDaemon = false
    /// The daemon searched every row (false while pages are still coming).
    public private(set) var isComplete = true
    /// The text the daemon gave for a regex it could not compile.
    public private(set) var invalidPattern: String?

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

    /// A search the daemon answers page by page (``append(page:map:columns:)``).
    public init(daemonQuery query: String) {
        self.query = query
        matches = []
        selected = nil
        fromDaemon = true
        isComplete = false
    }

    /// Adds a page: its matches are older than those held (pages come newest first). The
    /// highlighted match stays the same one; the first page highlights the newest.
    /// A restarted page (a reflow renumbered the markers) replaces what was held.
    public mutating func append(page: TerminalFindPage, map: TerminalFindRowMap, columns: Int) {
        if page.restarted {
            matches = []
            selected = nil
        }
        invalidPattern = page.invalidPattern
        let room = Self.limit - matches.count
        let older = page.hits.prefix(max(0, room)).reversed().map { Match(hit: $0, map: map, columns: columns) }
        let hadNone = matches.isEmpty
        matches.insert(contentsOf: older, at: 0)
        if hadNone { selected = matches.isEmpty ? nil : matches.count - 1 } else if let current = selected { selected = current + older.count }
        isComplete = page.complete || page.nextBefore == nil || matches.count >= Self.limit
    }

    /// The mirror was replaced or grew: lays every daemon match on its rows again.
    public mutating func remap(_ map: TerminalFindRowMap, columns: Int) {
        guard fromDaemon else { return }
        for index in matches.indices { matches[index].place(map: map, columns: columns) }
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
            var daemon = match.daemon
            daemon?.row += delta
            if let row = daemon?.row, row < 0 { continue }
            if index == selected { newSelected = kept.count }
            kept.append(Match(segments: segments, daemon: daemon))
        }
        matches = kept
        selected = kept.isEmpty ? nil : (newSelected ?? 0)
    }

    /// The match nearest `row` becomes the selected one (a search again after new
    /// output keeps the place the person was at).
    public mutating func select(nearestRow row: Int) {
        guard !matches.isEmpty else { return }
        var best = 0
        for (index, match) in matches.enumerated() where match.isLoaded && abs(match.row - row) <= abs(matches[best].row - row) { best = index }
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
