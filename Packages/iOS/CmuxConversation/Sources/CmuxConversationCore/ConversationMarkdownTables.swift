import Foundation

/// A Markdown table a bubble draws as aligned columns: the UTF-16 span of its
/// rows in the message's text (one line per row, cells split by tabs), and
/// each column's alignment from the table's delimiter row.
public struct ConversationTextTable: Sendable, Hashable, Codable {
    public enum Alignment: String, Sendable, Hashable, Codable { case leading, center, trailing }

    public var location: Int
    public var length: Int
    public var alignments: [Alignment]

    public init(location: Int, length: Int, alignments: [Alignment]) {
        self.location = location
        self.length = length
        self.alignments = alignments
    }

    public var range: NSRange { NSRange(location: location, length: length) }
}

/// GitHub-flavored Markdown tables (`| a | b |` over `| --- | :-: |`) to text a
/// bubble can show, as agents write them (Chief's subagent and status tables).
/// Bubbles are plain text, so without this the pipes and dashes show.
///
/// A table narrow enough for a phone bubble becomes rows of tab-separated
/// cells, its header bold, with a ``ConversationTextTable`` the bubble lays out
/// as columns. A wider one becomes one record per row, each cell on its own
/// line after its bold header ("**Status:** done"), so it stays readable on a
/// narrow screen. Every cell's text is kept; tables inside code fences are left
/// alone, and so is text with no table.
// lint:allow namespace-type -- pure helpers
public enum ConversationMarkdownTables {
    /// Widest row, in characters, still drawn as columns: cells plus a
    /// three-character gap between columns. Under a phone bubble's line at
    /// the default text size; wider tables are drawn as records. A row that
    /// still overflows (large text sizes, wide glyphs) wraps, never clips.
    public static let columnBudget = 30

    public struct Result: Sendable, Hashable {
        public var text: String
        public var tables: [ConversationTextTable]
        public var runs: [ConversationTextRun]
        public var links: [ConversationTextLink]
        public var mentions: [ConversationMention]
    }

    /// `text` with each table rewritten, its tables, and `runs`, `links` and
    /// `mentions` (UTF-16, over `text`) moved onto the new text. A link or
    /// mention cut by the rewrite (one spanning table syntax) is dropped.
    public static func extract(
        _ text: String,
        runs: [ConversationTextRun] = [],
        links: [ConversationTextLink] = [],
        mentions: [ConversationMention] = []
    ) -> Result {
        let unchanged = Result(text: text, tables: [], runs: runs, links: links, mentions: mentions)
        guard text.contains("|"), text.contains("-") else { return unchanged }
        let source = text as NSString
        let lines = Self.lines(source)
        let output = NSMutableString()
        var segments: [Segment] = []
        var tables: [ConversationTextTable] = []
        var headerRuns: [ConversationTextRun] = []
        var fence: String?
        var cursor = 0  // source location copied up to
        var index = 0
        var changed = false

        func copy(_ range: NSRange) {
            guard range.length > 0 else { return }
            segments.append(Segment(source: range, destination: output.length))
            output.append(source.substring(with: range))
        }

        while index < lines.count {
            let line = lines[index]
            let content = source.substring(with: line.content)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                index += 1
                continue
            }
            guard index + 1 < lines.count, content.contains("|"),
                  let alignments = Self.delimiter(source.substring(with: lines[index + 1].content)),
                  case let header = Self.cells(source, line.content), header.count == alignments.count
            else {
                index += 1
                continue
            }
            var body: [[Cell]] = []
            var end = index + 2
            while end < lines.count {
                let row = source.substring(with: lines[end].content)
                guard row.contains("|"), !row.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                body.append(Self.cells(source, lines[end].content))
                end += 1
            }
            // Copy everything before the table as written.
            copy(NSRange(location: cursor, length: line.content.location - cursor))
            let columns = alignments.count
            let rows = body.map { row in Array(row.prefix(columns)) + Array(repeating: Cell(pieces: []), count: max(0, columns - row.count)) }
            let widths = (0..<columns).map { column in
                ([header] + rows).map { $0[column].length(source) }.max() ?? 0
            }
            let fits = widths.reduce(0, +) + 3 * (columns - 1) <= columnBudget
            if fits {
                let start = output.length
                let leadingTab = alignments.first.map { $0 != .leading } ?? false
                for (rowIndex, row) in ([header] + rows).enumerated() {
                    if rowIndex > 0 { output.append("\n") }
                    if leadingTab { output.append("\t") }
                    for (column, cell) in row.enumerated() {
                        if column > 0 { output.append("\t") }
                        let cellStart = output.length
                        for piece in cell.pieces { copy(piece) }
                        if rowIndex == 0, output.length > cellStart {
                            headerRuns.append(ConversationTextRun(location: cellStart, length: output.length - cellStart, style: .bold))
                        }
                    }
                }
                tables.append(ConversationTextTable(location: start, length: output.length - start, alignments: alignments))
            } else {
                for (rowIndex, row) in rows.enumerated() {
                    if rowIndex > 0 { output.append("\n\n") }
                    var first = true
                    for (column, cell) in row.enumerated() {
                        let title = header[column]
                        guard !cell.pieces.isEmpty || !title.pieces.isEmpty else { continue }
                        if !first { output.append("\n") }
                        first = false
                        if !title.pieces.isEmpty {
                            let titleStart = output.length
                            for piece in title.pieces { copy(piece) }
                            output.append(":")
                            headerRuns.append(ConversationTextRun(location: titleStart, length: output.length - titleStart, style: .bold))
                            if !cell.pieces.isEmpty { output.append(" ") }
                        }
                        for piece in cell.pieces { copy(piece) }
                    }
                }
                if rows.isEmpty {
                    // A header alone: its titles, bold, on one line.
                    let titleStart = output.length
                    for (column, title) in header.enumerated() {
                        if column > 0 { output.append(" · ") }
                        for piece in title.pieces { copy(piece) }
                    }
                    headerRuns.append(ConversationTextRun(location: titleStart, length: output.length - titleStart, style: .bold))
                }
            }
            changed = true
            let last = lines[end - 1]
            cursor = NSMaxRange(last.content)
            index = end
        }
        guard changed else { return unchanged }
        copy(NSRange(location: cursor, length: source.length - cursor))

        let newText = output as String
        let movedRuns = runs.flatMap { run in
            Self.pieces(of: run.range, segments).map { ConversationTextRun(location: $0.location, length: $0.length, style: run.style, effect: run.effect) }
        }
        let movedLinks = links.compactMap { link in
            Self.whole(link.range, segments).map { ConversationTextLink(location: $0.location, length: $0.length, url: link.url) }
        }
        let movedMentions = mentions.compactMap { mention in
            Self.whole(NSRange(location: mention.location, length: mention.length), segments)
                .map { ConversationMention(participantID: mention.participantID, location: $0.location, length: $0.length) }
        }
        let allRuns = ConversationRichText.normalized(headerRuns + movedRuns, utf16Count: output.length)
        return Result(text: newText, tables: tables, runs: allRuns, links: movedLinks, mentions: movedMentions)
    }

    // MARK: - Parsing

    private struct Line { var content: NSRange }

    /// Source text copied verbatim to `destination` in the output.
    private struct Segment { var source: NSRange; var destination: Int }

    /// A cell's text: source ranges, split where `\|` drops its backslash.
    private struct Cell {
        var pieces: [NSRange]
        func length(_ source: NSString) -> Int {
            pieces.reduce(0) { $0 + (source.substring(with: $1) as String).count }
        }
    }

    private static func lines(_ source: NSString) -> [Line] {
        var result: [Line] = []
        var start = 0
        let newline = unichar(10), cr = unichar(13)
        for i in 0..<source.length where source.character(at: i) == newline {
            var end = i
            if end > start, source.character(at: end - 1) == cr { end -= 1 }
            result.append(Line(content: NSRange(location: start, length: end - start)))
            start = i + 1
        }
        result.append(Line(content: NSRange(location: start, length: source.length - start)))
        return result
    }

    /// The column alignments of a delimiter row (`| --- | :-: | --: |`), or nil.
    static func delimiter(_ line: String) -> [ConversationTextTable.Alignment]? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return nil }
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var result: [ConversationTextTable.Alignment] = []
        for part in parts {
            let cell = part.trimmingCharacters(in: .whitespaces)
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.dropFirst(left ? 1 : 0).dropLast(right && cell.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : right ? .trailing : .leading)
        }
        // A lone `---` is a rule or a setext heading, not a table.
        guard line.contains("|") else { return nil }
        return result
    }

    /// A row's cells, trimmed, the outer pipes dropped and `\|` kept as `|`.
    private static func cells(_ source: NSString, _ range: NSRange) -> [Cell] {
        let pipe = unichar(124), backslash = unichar(92)
        var cells: [Cell] = []
        var pieces: [NSRange] = []
        var pieceStart = range.location
        func endPiece(_ end: Int) {
            if end > pieceStart { pieces.append(NSRange(location: pieceStart, length: end - pieceStart)) }
        }
        var i = range.location
        while i < NSMaxRange(range) {
            let ch = source.character(at: i)
            if ch == backslash, i + 1 < NSMaxRange(range), source.character(at: i + 1) == pipe {
                endPiece(i)
                pieceStart = i + 1  // keep the pipe, drop the backslash
                i += 2
                continue
            }
            if ch == pipe {
                endPiece(i)
                cells.append(Cell(pieces: trim(pieces, source)))
                pieces = []
                pieceStart = i + 1
            }
            i += 1
        }
        endPiece(NSMaxRange(range))
        cells.append(Cell(pieces: trim(pieces, source)))
        // Outer pipes leave an empty first or last cell.
        let content = source.substring(with: range).trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|"), let first = cells.first, first.pieces.isEmpty { cells.removeFirst() }
        if content.hasSuffix("|"), !content.hasSuffix("\\|"), let last = cells.last, last.pieces.isEmpty { cells.removeLast() }
        return cells
    }

    /// `pieces` without leading and trailing whitespace.
    private static func trim(_ pieces: [NSRange], _ source: NSString) -> [NSRange] {
        var result = pieces
        func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }
        while var first = result.first {
            while first.length > 0, isSpace(source.character(at: first.location)) { first.location += 1; first.length -= 1 }
            if first.length == 0 { result.removeFirst() } else { result[0] = first; break }
        }
        while var last = result.last {
            while last.length > 0, isSpace(source.character(at: NSMaxRange(last) - 1)) { last.length -= 1 }
            if last.length == 0 { result.removeLast() } else { result[result.count - 1] = last; break }
        }
        return result
    }

    // MARK: - Moving ranges onto the new text

    /// `range` in the new text, if one copied segment holds all of it.
    private static func whole(_ range: NSRange, _ segments: [Segment]) -> NSRange? {
        for segment in segments where range.location >= segment.source.location && NSMaxRange(range) <= NSMaxRange(segment.source) {
            return NSRange(location: segment.destination + range.location - segment.source.location, length: range.length)
        }
        return nil
    }

    /// The parts of `range` the new text kept, in the new text.
    private static func pieces(of range: NSRange, _ segments: [Segment]) -> [NSRange] {
        segments.compactMap { segment in
            let overlap = NSIntersectionRange(range, segment.source)
            guard overlap.length > 0 else { return nil }
            return NSRange(location: segment.destination + overlap.location - segment.source.location, length: overlap.length)
        }
    }
}

extension ConversationTextTable {
    /// `tables` (over a message's whole text) moved onto a bubble that shows
    /// `bodyLength` UTF-16 units of it, starting `offset` units in, as
    /// ``ConversationTextLink/bubbleLinks(_:offset:bodyLength:)`` does.
    public static func bubbleTables(_ tables: [ConversationTextTable], offset: Int = 0, bodyLength: Int) -> [ConversationTextTable] {
        tables.compactMap { table in
            let location = table.location - offset
            guard location >= 0, location + table.length <= bodyLength else { return nil }
            return ConversationTextTable(location: location, length: table.length, alignments: table.alignments)
        }
    }
}

/// An array field added to a stored type after data was written without it
/// (``ConversationMessage/tables`` in a transcript cache written by an older
/// build): a missing key decodes as empty instead of failing the whole value.
@propertyWrapper
public struct ConversationEmptyWhenMissing<Element: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var wrappedValue: [Element]

    public init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode([Element].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    public func decode<Element>(_ type: ConversationEmptyWhenMissing<Element>.Type, forKey key: Key) throws -> ConversationEmptyWhenMissing<Element> {
        try decodeIfPresent(type, forKey: key) ?? ConversationEmptyWhenMissing(wrappedValue: [])
    }
}
