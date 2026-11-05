import Foundation

/// A web link in the terminal's rows: what a tap on it opens (the Mac's Cmd-click,
/// `TerminalHostDelegate.openWeb` and `TerminalWrappedLink`).
public struct TerminalLink: Equatable, Sendable {
    /// One row's piece of the link, in cells (`end` inclusive).
    public struct Segment: Equatable, Sendable {
        public var row: Int
        public var start: Int
        public var end: Int

        public init(row: Int, start: Int, end: Int) {
            self.row = row
            self.start = start
            self.end = end
        }
    }

    public var url: URL
    public var segments: [Segment]

    public init(url: URL, segments: [Segment]) {
        self.url = url
        self.segments = segments
    }
}

/// Finds the `http(s)://` link under a cell of the terminal's rows, the way the Mac
/// does for a Cmd-click: on the row itself, or across rows when a program broke the
/// URL onto several rows (Claude Code and Codex wrap long text with their own line
/// breaks): a row whose last word reaches the right edge goes on with the next row's
/// first word (a port of the Mac's `TerminalWrappedLink`).
///
/// ```swift
/// let finder = TerminalLinkFinder(rows: ["see https://cmux.com/docs now"], firstRow: 40, columns: 80)
/// finder.link(row: 40, column: 10)?.url  // https://cmux.com/docs
/// ```
public struct TerminalLinkFinder: Sendable {
    /// How far from the right edge a row's last word may end and still be broken by
    /// the program (a right margin), when the next row's word carries URL punctuation.
    static let edgeSlack = 3
    /// What a URL's continuation has that a prose word on the next row does not.
    static let continuationMarks: Set<Character> = ["/", "?", "=", "&", "%", "#"]
    /// Rows looked at above and below the tapped one.
    public static let reach = 6

    private let grid: [TerminalCellRow]
    private let firstRow: Int

    /// `rows[i]` is the text of row `firstRow + i`, one `Character` per grapheme as
    /// Ghostty reads it (a wide character takes two cells). A row that could not be
    /// read is empty.
    public init(rows: [String], firstRow: Int, columns: Int) {
        grid = rows.map { TerminalCellRow($0, columns: max(1, columns)) }
        self.firstRow = firstRow
    }

    /// The link that covers (`row`, `column`), or nil.
    public func link(row: Int, column: Int) -> TerminalLink? {
        let index = row - firstRow
        guard grid.indices.contains(index), let hit = grid[index].word(at: column) else { return nil }

        var pieces = [(index: index, word: hit)]
        // Back while the earlier row's last word was broken at the edge and this word starts its row.
        var current = index
        while current > grid.startIndex, pieces[0].word == grid[current].firstWord,
              let previous = grid[current - 1].lastWord,
              grid[current - 1].continues(previous, onto: grid[current].text(pieces[0].word)) {
            current -= 1
            pieces.insert((current, previous), at: 0)
        }
        // On while this word was broken at the edge and the next row starts with a word.
        current = index
        while current + 1 < grid.endIndex, let last = pieces.last?.word, last == grid[current].lastWord,
              let next = grid[current + 1].firstWord, grid[current].continues(last, onto: grid[current + 1].text(next)) {
            current += 1
            pieces.append((current, next))
        }

        // Cell offsets of each piece in the joined text, to find the URL around the tap.
        var joined = "", offsets: [Int] = []
        for piece in pieces {
            offsets.append(joined.count)
            joined += grid[piece.index].text(piece.word)
        }
        let hitPiece = pieces.firstIndex { $0.index == index } ?? 0
        let hitOffset = offsets[hitPiece] + grid[index].characterOffset(of: column, in: hit)
        let characters = Array(joined)
        guard let range = Self.webURL(in: characters, covering: hitOffset),
              let url = URL(string: String(characters[range])), url.host()?.isEmpty == false else { return nil }

        var segments: [TerminalLink.Segment] = []
        for (piece, offset) in zip(pieces, offsets) {
            let length = piece.word.characters.count
            let lower = max(range.lowerBound, offset), upper = min(range.upperBound, offset + length)
            guard lower < upper else { continue }
            let cells = grid[piece.index]
            segments.append(TerminalLink.Segment(row: firstRow + piece.index,
                                                 start: cells.column(ofCharacter: piece.word.characters.lowerBound + lower - offset),
                                                 end: cells.endColumn(ofCharacter: piece.word.characters.lowerBound + upper - offset - 1)))
        }
        guard !segments.isEmpty else { return nil }
        return TerminalLink(url: url, segments: segments)
    }

    /// The `http(s)://` URL in `characters` that covers `offset`, without trailing
    /// sentence punctuation.
    static func webURL(in characters: [Character], covering offset: Int) -> Range<Int>? {
        var searchFrom = 0
        while let start = schemeStart(in: characters, from: searchFrom) {
            var end = start
            while end < characters.count, isLinkCharacter(characters[end]) { end += 1 }
            while end > start, ".,;:!?'\"".contains(characters[end - 1]) { end -= 1 }
            if end > start, characters[end - 1] == ")",
               characters[start..<end].filter({ $0 == "(" }).count < characters[start..<end].filter({ $0 == ")" }).count {
                end -= 1
            }
            if start <= offset, offset < end { return start..<end }
            searchFrom = max(end, start + 1)
        }
        return nil
    }

    private static func schemeStart(in characters: [Character], from: Int) -> Int? {
        guard from < characters.count else { return nil }
        for start in from..<characters.count where characters[start] == "h" || characters[start] == "H" {
            for scheme in ["https://", "http://"] where start + scheme.count <= characters.count
                && String(characters[start..<start + scheme.count]).lowercased() == scheme {
                return start
            }
        }
        return nil
    }

    /// RFC 3986 characters plus `%`: what a printed URL is made of.
    static func isLinkCharacter(_ character: Character) -> Bool {
        guard character.isASCII, let ascii = character.asciiValue else { return false }
        if character.isLetter || character.isNumber { return true }
        return "-._~:/?#[]@!$&'()*+,;=%".utf8.contains(ascii)
    }

    /// Characters a program draws around text, never part of a link: box drawing
    /// (frames), block elements and Claude Code's tool-output elbow.
    static func isFrameCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return (0x2500...0x259F).contains(scalar.value) || character == "⎿" || character == "▌"
    }
}

/// One row as cells: each character with the column it starts at and its width.
struct TerminalCellRow: Sendable {
    struct Word: Equatable {
        /// Indices into `characters`.
        var characters: Range<Int>
    }

    let characters: [Character]
    let starts: [Int]
    let widths: [Int]
    let columns: Int

    init(_ text: String, columns: Int) {
        var characters: [Character] = [], starts: [Int] = [], widths: [Int] = []
        var column = 0
        for character in text where character != "\n" && character != "\r\n" {
            let width = Self.width(of: character)
            characters.append(character)
            starts.append(column)
            widths.append(width)
            column += width
        }
        self.characters = characters
        self.starts = starts
        self.widths = widths
        self.columns = columns
    }

    /// The link word that covers `column`, if that cell holds a link character.
    func word(at column: Int) -> Word? {
        guard let index = starts.indices.last(where: { starts[$0] <= column }),
              column < starts[index] + widths[index],
              TerminalLinkFinder.isLinkCharacter(characters[index]) else { return nil }
        var lower = index, upper = index + 1
        while lower > 0, TerminalLinkFinder.isLinkCharacter(characters[lower - 1]) { lower -= 1 }
        while upper < characters.count, TerminalLinkFinder.isLinkCharacter(characters[upper]) { upper += 1 }
        return Word(characters: lower..<upper)
    }

    /// The row's first word after indentation and frame characters.
    var firstWord: Word? {
        guard let index = characters.firstIndex(where: { !$0.isWhitespace && !TerminalLinkFinder.isFrameCharacter($0) }),
              TerminalLinkFinder.isLinkCharacter(characters[index]) else { return nil }
        return word(at: starts[index])
    }

    /// The row's last word before trailing spaces and frame characters.
    var lastWord: Word? {
        guard let index = characters.lastIndex(where: { !$0.isWhitespace && !TerminalLinkFinder.isFrameCharacter($0) }),
              TerminalLinkFinder.isLinkCharacter(characters[index]) else { return nil }
        return word(at: starts[index])
    }

    /// Whether `word`, the row's last, was broken by the program and goes on as `next`
    /// on the next row: it ends at the row's last cell, or right before a frame border,
    /// or within the edge slack when `next` carries URL punctuation.
    func continues(_ word: Word, onto next: String) -> Bool {
        guard !word.characters.isEmpty else { return false }
        let end = endColumn(ofCharacter: word.characters.upperBound - 1)
        if end >= columns - 1 { return true }
        // The row's outer frame border after at most one space (`… url │` at the edge).
        let after = characters[word.characters.upperBound...].drop(while: { $0 == " " })
        let gap = characters[word.characters.upperBound...].prefix(while: { $0 == " " }).count
        if gap <= 1, let border = after.first, TerminalLinkFinder.isFrameCharacter(border),
           after.dropFirst().allSatisfy(\.isWhitespace),
           endColumn(ofCharacter: characters.count - after.count) >= columns - 1 - TerminalLinkFinder.edgeSlack {
            return true
        }
        return end >= columns - 1 - TerminalLinkFinder.edgeSlack && next.contains { TerminalLinkFinder.continuationMarks.contains($0) }
    }

    func text(_ word: Word) -> String { String(characters[word.characters]) }

    func column(ofCharacter index: Int) -> Int { starts[index] }

    func endColumn(ofCharacter index: Int) -> Int { starts[index] + widths[index] - 1 }

    /// The character offset of `column` inside `word`.
    func characterOffset(of column: Int, in word: Word) -> Int {
        let index = word.characters.last { starts[$0] <= column } ?? word.characters.lowerBound
        return index - word.characters.lowerBound
    }

    /// The character index whose cell covers `column`, if any.
    func characterIndex(atColumn column: Int) -> Int? {
        guard let index = starts.indices.last(where: { starts[$0] <= column }), column < starts[index] + widths[index] else { return nil }
        return index
    }

    /// Cells a character takes: two for East Asian wide and emoji presentation.
    static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        if character.isASCII { return 1 }
        // An emoji presentation, by default or by VS16 (`⚠️`), takes two cells as in Ghostty.
        if scalar.properties.isEmojiPresentation || character.unicodeScalars.contains("\u{FE0F}") { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
