import Foundation

/// A message's Markdown as one short line of words, for every place that previews a message instead of drawing it:
/// a reply's quote of its root, a Home list row, a pinned tile.
///
/// A preview never shows syntax. Emphasis, code and heading markers go; a link shows its label; a pipe table is
/// named by its column titles ("Table: Before / After"); a picture (`![alt](source)`) is left out of the words and
/// listed in ``images`` so the caller can draw a real thumbnail; a message of pictures alone says how many. Code
/// keeps its text. White space folds to single spaces.
///
/// Pure and cheap: a text with nothing to strip costs one pass over its bytes, so a list can build a preview for
/// every row of every read.
///
/// ```swift
/// let preview = MessagePreview(markdown: "| | Before | After |\n|---|---|---|\n| Light | ![b](b.png) | ![a](a.png) |")
/// preview.text(words)   // "Table: Before / After"
/// preview.images.first  // MessagePreview.Image(alt: "b", source: "b.png")
/// ```
public struct MessagePreview: Sendable, Hashable {
    /// A picture the message names: `![alt](source)`, the source as written.
    public struct Image: Sendable, Hashable {
        /// The picture's alt text, as written.
        public var alt: String
        /// The picture's source as written (a path, a URL, `cmux-attachment:<hash>`), without angle brackets.
        public var source: String

        /// A picture with `alt` text and `source`.
        public init(alt: String, source: String) {
            self.alt = alt
            self.source = source
        }
    }

    /// A pipe table the message holds.
    public struct Table: Sendable, Hashable {
        /// The column titles that have words, in order (a matrix's empty corner is left out).
        public var columns: [String]
        /// How many body rows it has.
        public var rows: Int

        /// A table of `columns` titles and `rows` body rows.
        public init(columns: [String], rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    /// The words a preview says for what has no words of its own, in the reader's language. Each app builds it
    /// from its own string catalog.
    public struct Words: Sendable {
        /// A table with titled columns, given the titles joined ("Before / After"): "Table: Before / After".
        public var table: @Sendable (String) -> String
        /// A table whose columns have no titles: "Table".
        public var untitledTable: String
        /// One picture alone: "Image".
        public var image: String
        /// Several pictures alone, given how many: "2 images".
        public var images: @Sendable (Int) -> String

        /// Words from the caller's string catalog.
        /// - Parameters:
        ///   - table: formats a titled table from its titles joined by " / ".
        ///   - untitledTable: a table with no titles.
        ///   - image: one picture alone.
        ///   - images: several pictures alone, from their count.
        public init(table: @escaping @Sendable (String) -> String, untitledTable: String, image: String,
                    images: @escaping @Sendable (Int) -> String) {
            self.table = table
            self.untitledTable = untitledTable
            self.image = image
            self.images = images
        }
    }

    /// One piece of the message, in order.
    enum Piece: Sendable, Hashable {
        case words(String)
        case table(Table)
    }

    let pieces: [Piece]
    /// Every picture the message names, in order, the ones in table cells included.
    public let images: [Image]
    /// Every pipe table the message holds, in order.
    public var tables: [Table] { pieces.compactMap { if case let .table(t) = $0 { t } else { nil } } }

    /// The preview of `markdown`.
    public init(markdown: String) {
        var parser = PreviewParser()
        parser.parse(markdown)
        pieces = parser.pieces
        images = parser.images
    }

    /// The preview as one line: its words, each table by its titles, and when it has no words, its pictures'
    /// count. Empty for a message with nothing to show.
    public func text(_ words: Words) -> String {
        var parts: [String] = []
        for piece in pieces {
            switch piece {
            case let .words(w): parts.append(w)
            case let .table(t): parts.append(t.columns.isEmpty ? words.untitledTable : words.table(t.columns.joined(separator: " / ")))
            }
        }
        let line = folded(parts.joined(separator: " "))
        if !line.isEmpty || images.isEmpty { return line }
        return images.count == 1 ? words.image : words.images(images.count)
    }
}

/// `s` with every run of white space as one space, trimmed.
private func folded(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count)
    var space = false
    for ch in s {
        if ch.isWhitespace || ch.isNewline {
            space = !out.isEmpty
        } else {
            if space { out.append(" ") }
            space = false
            out.append(ch)
        }
    }
    return out
}

/// One pass over a message's lines: blocks (fences, tables, quotes, headings, list items, rules) by line, then each
/// line's inline Markdown.
private struct PreviewParser {
    var pieces: [MessagePreview.Piece] = []
    var images: [MessagePreview.Image] = []
    private var words = ""

    mutating func parse(_ markdown: String) {
        // Nothing that could be Markdown: the text as it is.
        if !markdown.utf8.contains(where: { Self.markers.contains($0) }) {
            words = markdown
            flush()
            return
        }
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
        var fence: Substring?
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil } else { append(String(line)) }
                i += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.prefix(3)
                i += 1
                continue
            }
            if line.contains("|"), i + 1 < lines.count, let columns = Self.delimiterColumns(lines[i + 1]) {
                let header = Self.cells(line)
                if header.count == columns {
                    var end = i + 2
                    var rows = 0
                    while end < lines.count, lines[end].contains("|"), !lines[end].allSatisfy({ $0 == " " || $0 == "\t" }) {
                        for cell in Self.cells(lines[end]) { _ = inline(cell) }
                        rows += 1
                        end += 1
                    }
                    flush()
                    let titles = header.map { folded(inline($0)) }.filter { !$0.isEmpty }
                    pieces.append(.table(MessagePreview.Table(columns: titles, rows: rows)))
                    i = end
                    continue
                }
            }
            append(inline(Self.blockBody(trimmed)))
            i += 1
        }
        flush()
    }

    private mutating func append(_ s: String) {
        guard !s.isEmpty else { return }
        if !words.isEmpty { words.append(" ") }
        words.append(s)
    }

    private mutating func flush() {
        let w = folded(words)
        if !w.isEmpty { pieces.append(.words(w)) }
        words = ""
    }

    /// Bytes that may start Markdown syntax; a text with none of them is plain.
    static let markers: Set<UInt8> = Set("*_`#>[]!|<\\~-+=".utf8)

    /// A line without its block markers: quote marks, a heading's hashes, a bullet and a task box (a numbered item
    /// keeps its number, which says something). A rule or a setext underline has no words.
    static func blockBody(_ line: Substring) -> Substring {
        var s = line
        while s.first == ">" { s = s.dropFirst().drop { $0 == " " } }
        let bare = s.filter { $0 != " " }
        if bare.count >= 3, let c = bare.first, "-*_=".contains(c), bare.allSatisfy({ $0 == c }) { return "" }
        let hashes = s.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), s.dropFirst(hashes).first == " " || s.count == hashes {
            s = s.dropFirst(hashes).drop { $0 == " " }
            while s.last == "#" || s.last == " " { s = s.dropLast() }
            return s
        }
        if let c = s.first, "-*+".contains(c), s.dropFirst().first == " " { s = s.dropFirst(2) }
        for box in ["[ ] ", "[x] ", "[X] "] where s.hasPrefix(box) { s = s.dropFirst(box.count) }
        return s
    }

    /// The column count of a table's delimiter row (`| --- | :-: |`), or nil.
    static func delimiterColumns(_ line: Substring) -> Int? {
        guard line.contains("-"), line.contains("|") || line.contains(":") else { return nil }
        let cells = Self.cells(line)
        guard !cells.isEmpty else { return nil }
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            var dashes = Substring(c)
            if dashes.first == ":" { dashes = dashes.dropFirst() }
            if dashes.last == ":" { dashes = dashes.dropLast() }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        }
        return cells.count
    }

    /// A table row's cells, trimmed, its outer pipes dropped; `\|` and a pipe inside a code span stay in the cell.
    static func cells(_ line: Substring) -> [Substring] {
        var cells: [Substring] = []
        var start = line.startIndex
        var i = line.startIndex
        var code = false
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\\" {
                i = line.index(after: i)
                if i < line.endIndex { i = line.index(after: i) }
                continue
            }
            if ch == "`" { code.toggle() }
            if ch == "|", !code {
                cells.append(line[start..<i])
                start = line.index(after: i)
            }
            i = line.index(after: i)
        }
        cells.append(line[start...])
        let content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|"), let first = cells.first, first.allSatisfy({ $0 == " " || $0 == "\t" }) { cells.removeFirst() }
        if content.hasSuffix("|"), !content.hasSuffix("\\|"), let last = cells.last, last.allSatisfy({ $0 == " " || $0 == "\t" }) {
            cells.removeLast()
        }
        return cells.map { $0.drop { $0 == " " || $0 == "\t" } }.map { cell in
            var c = cell
            while c.last == " " || c.last == "\t" { c = c.dropLast() }
            return c
        }
    }

    /// One line's inline Markdown as its words: links by their labels, pictures left out (and listed), code by its
    /// text, emphasis and strike markers gone, backslash escapes resolved.
    mutating func inline(_ s: Substring) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        func isWordChar(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
        func isSpace(_ c: Character?) -> Bool { c.map { $0.isWhitespace } ?? true }
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "\\" where chars[safe: i + 1].map { $0.isASCII && ($0.isPunctuation || $0.isSymbol) } ?? false:
                out.append(chars[i + 1])
                i += 2
                continue
            case "`":
                let run = chars[i...].prefix { $0 == "`" }.count
                // The matching run of as many backticks closes the span; without one the backticks are text.
                var j = i + run
                var close: Int?
                while j < chars.count {
                    if chars[j] == "`" {
                        let r = chars[j...].prefix { $0 == "`" }.count
                        if r == run { close = j; break }
                        j += r
                    } else {
                        j += 1
                    }
                }
                if let close {
                    out += String(chars[(i + run)..<close]).trimmingCharacters(in: .whitespaces)
                    i = close + run
                } else {
                    i += run
                }
                continue
            case "!" where chars[safe: i + 1] == "[":
                if let (label, target, end) = Self.link(chars, at: i + 1) {
                    images.append(MessagePreview.Image(alt: label, source: Self.source(target)))
                    i = end
                    continue
                }
            case "[":
                if let (label, _, end) = Self.link(chars, at: i) {
                    out += inline(Substring(label))
                    i = end
                    continue
                }
            case "<":
                // <https://…> autolink: the URL.
                if let close = chars[(i + 1)...].firstIndex(of: ">"), close > i + 1 {
                    let inside = String(chars[(i + 1)..<close])
                    if inside.contains(":"), !inside.contains(" ") {
                        out += inside
                        i = close + 1
                        continue
                    }
                }
            case "*", "_", "~":
                let run = chars[i...].prefix { $0 == ch }.count
                let before = i > 0 ? chars[i - 1] : nil
                let after = chars[safe: i + run]
                // An emphasis or strike marker opens before a word or closes after one; `_` inside a word
                // (snake_case) and a lone `*` between spaces stay.
                let opens = !isSpace(after) && (isSpace(before) || !isWordChar(before))
                let closes = !isSpace(before) && (isSpace(after) || !isWordChar(after))
                let intraword = isWordChar(before) && isWordChar(after)
                let marker = (ch == "~" ? run == 2 : run <= 3) && (opens || closes) && !(ch == "_" && intraword)
                if marker {
                    i += run
                    continue
                }
                out += String(repeating: ch, count: run)
                i += run
                continue
            default:
                break
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    /// `[label](target)` at `i` (the `[`): the label, the target and the index after the `)`; nil when not a link.
    static func link(_ chars: [Character], at i: Int) -> (String, String, Int)? {
        guard chars[safe: i] == "[" else { return nil }
        var depth = 0
        var j = i
        var close: Int?
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "[" { depth += 1 }
            if chars[j] == "]" {
                depth -= 1
                if depth == 0 { close = j; break }
            }
            j += 1
        }
        guard let close, chars[safe: close + 1] == "(" else { return nil }
        var k = close + 2
        var parens = 1
        while k < chars.count {
            if chars[k] == "(" { parens += 1 }
            if chars[k] == ")" {
                parens -= 1
                if parens == 0 { break }
            }
            k += 1
        }
        guard k < chars.count else { return nil }
        return (String(chars[(i + 1)..<close]), String(chars[(close + 2)..<k]), k + 1)
    }

    /// A link target's source: without a title (`src "title"`) and angle brackets.
    static func source(_ target: String) -> String {
        var t = target.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("<"), let end = t.firstIndex(of: ">") { return String(t[t.index(after: t.startIndex)..<end]) }
        if let space = t.firstIndex(of: " ") { t = String(t[..<space]) }
        return t
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
