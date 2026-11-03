import Foundation

/// A web link a program broke onto several rows itself. Claude Code, Codex and
/// other full-screen programs wrap long text with their own line breaks, so
/// Ghostty sees one row's piece of the URL and a Cmd-click there opened half
/// of it. A row whose last word reaches the right edge continues on the next
/// row's first word; the joined text is a link when it holds an `http(s)://`
/// URL that covers the pointer's cell. Only links that span two or more rows
/// come from here: Ghostty matches the rest itself.
nonisolated struct TerminalWrappedLink: Equatable, Sendable {
    /// One row's piece, in viewport cells (`end` inclusive).
    struct Segment: Equatable, Sendable {
        var row: Int
        var start: Int
        var end: Int
    }

    var text: String
    var segments: [Segment]

    /// How far from the right edge a row's last word may end and still be
    /// broken by the program (a right margin), when the next row's word carries
    /// URL punctuation. A word that reaches the last column always continues.
    static let edgeSlack = 3
    /// What a URL's continuation has that a prose word on the next row does not.
    static let continuationMarks: Set<Character> = ["/", "?", "=", "&", "%", "#"]
    /// Rows looked at above and below the pointer.
    static let reach = 6

    /// The wrapped link under (`column`, `row`), from the viewport rows around it.
    /// `rows[row - firstRow]` is the text of viewport row `row`, one `Character` per
    /// grapheme as Ghostty reads it; a wide character takes two cells. `hint`: the link Ghostty
    /// reports under the pointer; rows whose words join into part of it continue whatever their
    /// edge (Ghostty joined a row the terminal wrapped, but underlines only the pointer's row).
    static func find(rows: [String], firstRow: Int, columns: Int, column: Int, row: Int, hint: String? = nil) -> TerminalWrappedLink? {
        let grid = rows.map { Cells($0, columns: columns) }
        let index = row - firstRow
        guard grid.indices.contains(index), let hit = grid[index].word(at: column) else { return nil }

        var pieces = [(row: row, word: hit)]
        var chain = grid[index].text(hit)
        // Whether `text` is part of Ghostty's link, so these rows are one link whatever their edges.
        let inHint = { (text: String) in hint?.contains(text) ?? false }
        // Back while the earlier row's last word was broken at the edge and this word starts its row.
        var current = index
        while current > grid.startIndex, pieces[0].word == grid[current].firstWord,
              let previous = grid[current - 1].lastWord,
              grid[current - 1].continues(previous, onto: grid[current].text(pieces[0].word))
                || inHint(grid[current - 1].text(previous) + chain) {
            current -= 1
            pieces.insert((firstRow + current, previous), at: 0)
            chain = grid[current].text(previous) + chain
        }
        // On while this word was broken at the edge and the next row starts with a word.
        current = index
        while current + 1 < grid.endIndex, let last = pieces.last?.word, last == grid[current].lastWord,
              let next = grid[current + 1].firstWord,
              grid[current].continues(last, onto: grid[current + 1].text(next)) || inHint(chain + grid[current + 1].text(next)) {
            current += 1
            pieces.append((firstRow + current, next))
            chain += grid[current].text(next)
        }
        guard pieces.count > 1 else { return nil }

        // Cell offsets of each piece in the joined text, to find the URL around the pointer.
        var joined = "", offsets: [Int] = []
        for piece in pieces {
            offsets.append(joined.count)
            joined += grid[piece.row - firstRow].text(piece.word)
        }
        let hitOffset = offsets[pieces.firstIndex { $0.row == row } ?? 0]
            + grid[index].characterOffset(of: column, in: hit)
        guard let url = webURL(in: joined, covering: hitOffset) else { return nil }

        var segments: [Segment] = []
        for (piece, offset) in zip(pieces, offsets) {
            let length = piece.word.characters.count
            let lower = max(url.lowerBound, offset), upper = min(url.upperBound, offset + length)
            guard lower < upper else { continue }
            let cells = grid[piece.row - firstRow]
            segments.append(Segment(row: piece.row,
                                    start: cells.column(ofCharacter: piece.word.characters.lowerBound + lower - offset),
                                    end: cells.endColumn(ofCharacter: piece.word.characters.lowerBound + upper - offset - 1)))
        }
        guard segments.count > 1 else { return nil }
        let characters = Array(joined)
        return TerminalWrappedLink(text: String(characters[url]), segments: segments)
    }

    /// The `http(s)://` URL in `text` that covers character `offset`, without trailing
    /// sentence punctuation.
    private static func webURL(in text: String, covering offset: Int) -> Range<Int>? {
        let characters = Array(text)
        var searchFrom = 0
        while let start = schemeStart(in: characters, from: searchFrom) {
            var end = start
            while end < characters.count, isLinkCharacter(characters[end]) { end += 1 }
            while end > start, ".,;:!?'\"".contains(characters[end - 1]) { end -= 1 }
            if end > start, characters[end - 1] == ")", characters[start..<end].filter({ $0 == "(" }).count < characters[start..<end].filter({ $0 == ")" }).count {
                end -= 1
            }
            if start <= offset, offset < end { return start..<end }
            searchFrom = max(end, start + 1)
        }
        return nil
    }

    private static func schemeStart(in characters: [Character], from: Int) -> Int? {
        guard from < characters.count else { return nil }
        for start in from..<characters.count where characters[start] == "h" {
            for scheme in ["https://", "http://"] where start + scheme.count <= characters.count
                && String(characters[start..<start + scheme.count]) == scheme {
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

/// One viewport row as cells: each character with the column it starts at.
private nonisolated struct Cells {
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
        for character in text where character != "\n" {
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
              TerminalWrappedLink.isLinkCharacter(characters[index]) else { return nil }
        var lower = index, upper = index + 1
        while lower > 0, TerminalWrappedLink.isLinkCharacter(characters[lower - 1]) { lower -= 1 }
        while upper < characters.count, TerminalWrappedLink.isLinkCharacter(characters[upper]) { upper += 1 }
        return Word(characters: lower..<upper)
    }

    /// The row's first word after indentation and frame characters.
    var firstWord: Word? {
        guard let index = characters.firstIndex(where: { !$0.isWhitespace && !TerminalWrappedLink.isFrameCharacter($0) }),
              TerminalWrappedLink.isLinkCharacter(characters[index]) else { return nil }
        return word(at: starts[index])
    }

    /// The row's last word before trailing spaces and frame characters.
    var lastWord: Word? {
        guard let index = characters.lastIndex(where: { !$0.isWhitespace && !TerminalWrappedLink.isFrameCharacter($0) }),
              TerminalWrappedLink.isLinkCharacter(characters[index]) else { return nil }
        return word(at: starts[index])
    }

    /// Whether `word`, the row's last, was broken by the program and goes on as `next`
    /// on the next row: it ends at the row's last cell, or right before a frame border, or
    /// within the edge slack when `next` carries URL punctuation. A URL that ends a few
    /// cells short of the edge, followed by prose, stays whole.
    func continues(_ word: Word, onto next: String) -> Bool {
        guard !word.characters.isEmpty else { return false }
        let end = endColumn(ofCharacter: word.characters.upperBound - 1)
        if end >= columns - 1 { return true }
        // The row's outer frame border after at most one space: `… url │` with the `│` the row's
        // last character near the edge. A table's column border (`│ url │ next`) is not one.
        let after = characters[word.characters.upperBound...].drop(while: { $0 == " " })
        let gap = characters[word.characters.upperBound...].prefix(while: { $0 == " " }).count
        if gap <= 1, let border = after.first, TerminalWrappedLink.isFrameCharacter(border),
           after.dropFirst().allSatisfy(\.isWhitespace),
           endColumn(ofCharacter: characters.count - after.count) >= columns - 1 - TerminalWrappedLink.edgeSlack {
            return true
        }
        return end >= columns - 1 - TerminalWrappedLink.edgeSlack && next.contains { TerminalWrappedLink.continuationMarks.contains($0) }
    }

    func text(_ word: Word) -> String { String(characters[word.characters]) }

    func column(ofCharacter index: Int) -> Int { starts[index] }

    func endColumn(ofCharacter index: Int) -> Int { starts[index] + widths[index] - 1 }

    /// The character offset of `column` inside `word`.
    func characterOffset(of column: Int, in word: Word) -> Int {
        let index = word.characters.last { starts[$0] <= column } ?? word.characters.lowerBound
        return index - word.characters.lowerBound
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
