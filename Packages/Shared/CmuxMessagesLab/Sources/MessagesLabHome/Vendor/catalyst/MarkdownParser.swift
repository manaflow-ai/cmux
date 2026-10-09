import Foundation

// Markdown for message bubbles (shared/MARKDOWN.md). CommonMark block and inline
// structure plus the GFM extensions (tables, task lists, strikethrough, extended
// autolinks), written for chat:
// - A newline inside a paragraph is a line break (chat text keeps its lines).
// - Raw HTML is never interpreted: tags are literal text. Images are never
//   loaded: `![alt](src)` is a link that shows the alt text.
// - Table rows keep cells beyond the header's count (GFM drops them); a pipe in
//   a code span does not split a cell.
// The parser is pure (Foundation only, no UIKit), thread safe and runs off main.
// Top-level blocks carry their source line range, so a stream re-parses only
// from the start of its last top-level block (MarkdownStore).

/// cmux (interim, until MessagesLab ships the same API): the destinations that become links.
/// Only http, https and mailto (plus a host's `extraSchemes`); any other scheme, an obfuscated
/// scheme and a relative URL stay plain text, and a click re-checks with `url(_:)`.
enum MarkdownLinkPolicy {
    /// Schemes a host allows besides http, https and mailto (lowercase; empty by default).
    static var extraSchemes: Set<String> = []

    /// `dest` as a URL a click may open, or nil (plain text). The scheme must be the literal
    /// start of the destination (ASCII letters, digits, "+", "-", "."): no whitespace, control,
    /// entity or percent-encoded character can hide it.
    static func url(_ dest: String) -> URL? {
        guard let colon = dest.firstIndex(of: ":") else { return nil }
        let scheme = dest[..<colon].unicodeScalars
        guard let first = scheme.first, first.isASCII, CharacterSet.letters.contains(first),
              scheme.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) })
        else { return nil }
        let s = String(String.UnicodeScalarView(scheme)).lowercased()
        guard ["http", "https", "mailto"].contains(s) || extraSchemes.contains(s) else { return nil }
        guard !dest.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: dest), url.scheme?.lowercased() == s else { return nil }
        if s == "http" || s == "https" { guard let host = url.host, !host.isEmpty else { return nil } }
        return url
    }

    static func allows(_ dest: String) -> Bool { url(dest) != nil }
}

/// Inline styles of a run of display text.
struct MDStyle: OptionSet, Hashable {
    let rawValue: UInt16
    static let emphasis = MDStyle(rawValue: 1)
    static let strong = MDStyle(rawValue: 2)
    static let strike = MDStyle(rawValue: 4)
    static let code = MDStyle(rawValue: 8)
    static let link = MDStyle(rawValue: 16)
    static let image = MDStyle(rawValue: 32)
}

/// One styled run: a UTF-16 range of `MDText.string`.
struct MDSpan: Hashable {
    var location: Int
    var length: Int
    var style: MDStyle
    var link: String?
}

/// Inline content, flattened: the display string and its styled runs.
/// Line breaks are "\n" in the string.
struct MDText: Hashable {
    var string: String = ""
    var spans: [MDSpan] = []
    var isEmpty: Bool { string.isEmpty }
}

enum MDAlign: Hashable { case none, left, center, right }

struct MDTable: Hashable {
    var aligns: [MDAlign]
    var header: [MDText]
    var rows: [[MDText]]
    var columns: Int { aligns.count }
}

struct MDItem: Hashable {
    /// The marker as written: "-", "*", "+", "3.", "4)".
    var marker: String
    /// nil: not a task; false: "[ ]"; true: "[x]".
    var task: Bool?
    var blocks: [MDBlock]
}

struct MDList: Hashable {
    var ordered: Bool
    var start: Int
    /// Loose: a blank line between items or inside an item.
    var loose: Bool
    var items: [MDItem]
}

struct MDBlock: Hashable {
    indirect enum Kind: Hashable {
        case paragraph(MDText)
        case heading(level: Int, MDText)
        /// `closed` is false for a fence that runs to the end of the text (a stream).
        case code(lang: String, text: String, fenced: Bool, closed: Bool)
        case quote([MDBlock])
        case list(MDList)
        case table(MDTable)
        case rule
    }
    var kind: Kind
    /// Rendering differs from the plain text path (MDDocument.isRich).
    var rich = true
    /// A blank line separates this block from the one before it (same container).
    var blankBefore: Bool = false
    /// Source lines [lower, upper) (top-level blocks only; 0..<0 inside containers).
    var lines: Range<Int> = 0..<0
}

struct MDDocument: Hashable {
    var blocks: [MDBlock]
    /// Whether rendering differs from plain text: any block other than a plain
    /// paragraph, or any styled run other than an autolink. Plain documents keep the
    /// plain text path (same pixels as before markdown existed).
    var isRich: Bool
}

enum Markdown {
    /// Off for one run with `--no-markdown` (A/B and the diff harness's plain baseline).
    static var enabled = !ProcessInfo.processInfo.arguments.contains("--no-markdown")

    /// Cheap pre-check (no allocation): could this text contain markdown syntax?
    /// False means the plain path for sure.
    static func mightContain(_ text: String) -> Bool {
        var lineStart = true
        var indent = 0
        for b in text.utf8 {
            if b == 10 || b == 13 { lineStart = true; indent = 0; continue }
            if lineStart, b == 32 || b == 9 {
                indent += b == 9 ? 4 : 1
                if indent >= 4 { return true }                              // indented code
                continue
            }
            switch b {
            case 42, 95, 96, 126, 124, 91, 92, 38, 60: return true          // * _ ` ~ | [ \ & <
            case 35, 62, 43, 45, 61, 48...57: if lineStart { return true }   // # > + - = digit at a line start
            default: break
            }
            lineStart = false
        }
        return false
    }

    /// Parse a whole text.
    static func parse(_ text: String) -> MDDocument {
        let lines = MDLines.split(text).map { MDLine($0) }
        var refs = MDRefs()
        var blocks = MDBlockParser.parse(lines, refs: &refs, known: nil, topLevel: true)
        // Reference links may point forward: a second pass with every definition.
        if !refs.isEmpty {
            var again = MDRefs()
            blocks = MDBlockParser.parse(lines, refs: &again, known: refs, topLevel: true)
        }
        return MDDocument(blocks: blocks, isRich: blocks.contains { $0.rich })
    }
}

extension MDBlock {
    /// A paragraph is plain when its only runs are bare links (the plain path detects
    /// those too) and its display text equals its source apart from whitespace.
    static func paragraphIsRich(_ t: MDText, source: String) -> Bool {
        if t.spans.contains(where: { $0.style != .link }) { return true }
        func squeeze(_ s: String) -> String { String(s.unicodeScalars.filter { $0 != " " && $0 != "\t" && $0 != "\n" }.map(Character.init)) }
        return squeeze(t.string) != squeeze(source)
    }
}

// MARK: - Lines

enum MDLines {
    /// Lines split at LF, CRLF and CR. A final newline does not add an empty line.
    static func split(_ text: String) -> [Substring] {
        var out: [Substring] = []
        var start = text.startIndex
        var i = text.startIndex
        let u = text.unicodeScalars
        var si = u.startIndex
        while si < u.endIndex {
            let c = u[si]
            if c == "\n" || c == "\r" {
                i = si
                out.append(text[start..<i])
                var next = u.index(after: si)
                if c == "\r", next < u.endIndex, u[next] == "\n" { next = u.index(after: next) }
                start = next
                si = next
                continue
            }
            si = u.index(after: si)
        }
        if start < text.endIndex { out.append(text[start..<text.endIndex]) }
        return out
    }
}

/// A source line as Unicode scalars, with column arithmetic (tabs stop every 4 columns).
struct MDLine {
    var s: [Unicode.Scalar]
    init(_ sub: Substring) { s = Array(sub.unicodeScalars) }
    init(scalars: [Unicode.Scalar]) { s = scalars }

    var isBlank: Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    /// Columns of leading whitespace.
    var indent: Int {
        var col = 0
        for c in s {
            if c == " " { col += 1 } else if c == "\t" { col += 4 - col % 4 } else { break }
        }
        return col
    }

    /// The line with `cols` columns of leading whitespace removed (a partly used tab
    /// leaves spaces). Removes at most the leading whitespace.
    func dropping(cols: Int) -> MDLine {
        var col = 0, i = 0
        while i < s.count, col < cols {
            if s[i] == " " { col += 1; i += 1 }
            else if s[i] == "\t" {
                let w = 4 - col % 4
                if col + w > cols {
                    let rest = col + w - cols
                    return MDLine(scalars: Array(repeating: " ", count: rest) + s[(i + 1)...])
                }
                col += w; i += 1
            } else { break }
        }
        return MDLine(scalars: Array(s[i...]))
    }

    /// Leading whitespace removed.
    var trimmedLeading: MDLine { var i = 0; while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }; return MDLine(scalars: Array(s[i...])) }
    var string: String { var v = String.UnicodeScalarView(); v.append(contentsOf: s); return String(v) }
    func string(_ r: Range<Int>) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: s[r]); return String(v) }
}

// MARK: - Link reference definitions

struct MDRefs {
    var map: [String: (String, String?)] = [:]
    var isEmpty: Bool { map.isEmpty }
    static func normalize(_ label: String) -> String {
        label.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ").lowercased()
    }
}

// MARK: - Blocks

enum MDBlockParser {
    static let maxDepth = 32

    /// Parse lines of one container into blocks.
    static func parse(_ lines: [MDLine], refs: inout MDRefs, known: MDRefs?, topLevel: Bool = false, depth: Int = 0) -> [MDBlock] {
        var out: [MDBlock] = []
        var i = 0
        var blank = false
        // Pathological nesting: past maxDepth, containers stay literal paragraphs.
        let nest = depth < maxDepth
        func add(_ k: MDBlock.Kind, _ from: Int) {
            out.append(MDBlock(kind: k, blankBefore: blank && !out.isEmpty, lines: topLevel ? from..<i : 0..<0))
            blank = false
        }
        while i < lines.count {
            let line = lines[i]
            if line.isBlank { blank = true; i += 1; continue }
            let start = i
            let ind = line.indent
            // Indented code.
            if ind >= 4 {
                var body: [MDLine] = []
                while i < lines.count, lines[i].isBlank || lines[i].indent >= 4 {
                    body.append(lines[i].dropping(cols: 4)); i += 1
                }
                while body.last?.isBlank == true { body.removeLast(); i -= 1 }
                add(.code(lang: "", text: body.map(\.string).joined(separator: "\n"), fenced: false, closed: true), start)
                continue
            }
            let t = line.dropping(cols: ind)
            // Fenced code.
            if let f = fence(t) {
                var body: [MDLine] = []
                var closed = false
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.indent < 4, let c = fence(l.dropping(cols: l.indent)), c.char == f.char, c.count >= f.count, c.info.isEmpty {
                        closed = true; i += 1; break
                    }
                    body.append(l.dropping(cols: ind)); i += 1
                }
                add(.code(lang: f.info.split(separator: " ").first.map(String.init) ?? "", text: body.map(\.string).joined(separator: "\n"),
                          fenced: true, closed: closed), start)
                continue
            }
            if let (level, text) = atxHeading(t) {
                i += 1
                add(.heading(level: level, MDInlineParser.parse(text, refs: known)), start)
                continue
            }
            if isRule(t) { i += 1; add(.rule, start); continue }
            if nest, t.s.first == ">" {
                var inner: [MDLine] = []
                var lastParagraph = false
                while i < lines.count {
                    let l = lines[i]
                    let li = l.indent
                    if li < 4, l.dropping(cols: li).s.first == ">" {
                        var q = l.dropping(cols: li)
                        q = MDLine(scalars: Array(q.s.dropFirst()))
                        if q.s.first == " " { q = MDLine(scalars: Array(q.s.dropFirst())) }
                        else if q.s.first == "\t" { q = q.dropping(cols: 1) }
                        inner.append(q)
                        // Through nested quote markers: lazy lines continue the deepest paragraph.
                        var deep = q.dropping(cols: q.indent)
                        while deep.s.first == ">" { deep = MDLine(scalars: Array(deep.s.dropFirst())); deep = deep.dropping(cols: deep.indent) }
                        lastParagraph = !deep.isBlank && !startsBlock(deep) && q.indent < 4
                        i += 1
                    } else if lastParagraph, !l.isBlank, !startsBlock(l.dropping(cols: li)) {
                        inner.append(l); i += 1          // lazy continuation
                    } else { break }
                }
                add(.quote(parse(inner, refs: &refs, known: known, depth: depth + 1)), start)
                continue
            }
            if nest, let m = listMarker(t, interruptsParagraph: false) {
                let blankBeforeList = blank
                var blankAfter = false
                var items: [MDItem] = []
                var loose = false
                var startNumber = m.number
                let ordered = m.ordered
                let delim = m.delim
                while i < lines.count {
                    let l = lines[i]
                    let li = l.indent
                    guard li < 4, let mk = listMarker(l.dropping(cols: li), interruptsParagraph: false),
                          mk.ordered == ordered, mk.delim == delim else { break }
                    if items.isEmpty { startNumber = mk.number }
                    let contentIndent = li + mk.width
                    var body: [MDLine] = [mk.first]
                    i += 1
                    var lastParagraph = !mk.first.isBlank
                    var sawBlank = mk.first.isBlank
                    var innerBlank = false
                    while i < lines.count {
                        let l2 = lines[i]
                        if l2.isBlank {
                            // An item may start with at most one blank line.
                            if body.count == 1, body[0].isBlank { break }
                            body.append(MDLine(scalars: [])); i += 1; sawBlank = true; lastParagraph = false; continue
                        }
                        if l2.indent >= contentIndent {
                            if sawBlank, body.contains(where: { !$0.isBlank }) { innerBlank = true }
                            sawBlank = false
                            let d = l2.dropping(cols: contentIndent)
                            body.append(d); i += 1
                            lastParagraph = !startsBlock(d.dropping(cols: d.indent)) || d.indent >= 4
                            continue
                        }
                        // A list marker below the content column is the next item (or a new list), never lazy text.
                        if listMarker(l2.dropping(cols: l2.indent), interruptsParagraph: false) != nil { break }
                        if !sawBlank, lastParagraph, !startsBlock(l2.dropping(cols: l2.indent)) {
                            body.append(l2.trimmedLeading); i += 1; continue   // lazy continuation
                        }
                        break
                    }
                    // Trailing blank lines belong between items, not to this item.
                    var trailing = 0
                    while body.count > 1, body.last?.isBlank == true { body.removeLast(); trailing += 1 }
                    if innerBlank { loose = true }
                    var blocks = parse(body, refs: &refs, known: known, depth: depth + 1)
                    var task: Bool?
                    if case let .paragraph(p)? = blocks.first?.kind, let (checked, rest) = taskPrefix(p) {
                        task = checked
                        blocks[0].kind = .paragraph(rest)
                    }
                    items.append(MDItem(marker: mk.marker, task: task, blocks: blocks))
                    if trailing > 0 {
                        // A blank line then another item of this list: loose.
                        if i < lines.count, lines[i].indent < 4,
                           let n = listMarker(lines[i].dropping(cols: lines[i].indent), interruptsParagraph: false),
                           n.ordered == ordered, n.delim == delim { loose = true } else { blankAfter = true; break }
                    }
                }
                blank = blankBeforeList
                add(.list(MDList(ordered: ordered, start: startNumber, loose: loose, items: items)), start)
                blank = blankAfter
                continue
            }
            // Table: a header row, then a delimiter row with the same cell count.
            if i + 1 < lines.count, let tb = table(lines, at: i, known) {
                i = tb.end
                add(.table(tb.table), start)
                continue
            }
            // Paragraph (maybe link reference definitions, maybe a setext heading,
            // maybe ending in a table header).
            var para: [MDLine] = [t]
            i += 1
            var setext = 0
            var tableAt: Int?
            while i < lines.count {
                let l = lines[i]
                if l.isBlank { break }
                let li = l.indent
                let d = l.dropping(cols: li)
                if li < 4, let level = setextLevel(d) { setext = level; i += 1; break }
                if li < 4, startsBlock(d, interrupting: true) { break }
                if table(lines, at: i, known) != nil { tableAt = i; break }
                para.append(d); i += 1
            }
            // Leading link reference definitions.
            var text = para.map { $0.string }.joined(separator: "\n")
            text = definitions(text, into: &refs)
            if setext > 0 {
                if !text.isEmpty { add(.heading(level: setext, MDInlineParser.parse(text, refs: known)), start) }
                else { add(.paragraph(MDInlineParser.parse(para.last?.string ?? "", refs: known)), start) }
            } else if !text.isEmpty {
                let p = MDInlineParser.parse(text, refs: known)
                add(.paragraph(p), start)
                out[out.count - 1].rich = MDBlock.paragraphIsRich(p, source: text)
            }
            if let at = tableAt, let tb = table(lines, at: at, known) {
                let s2 = i
                i = tb.end
                add(.table(tb.table), s2)
            }
        }
        return out
    }

    // MARK: Leaf recognizers

    struct Fence { var char: Unicode.Scalar; var count: Int; var info: String }
    static func fence(_ t: MDLine) -> Fence? {
        guard let c = t.s.first, c == "`" || c == "~" else { return nil }
        var n = 0
        while n < t.s.count, t.s[n] == c { n += 1 }
        guard n >= 3 else { return nil }
        let info = t.string(n..<t.s.count).trimmingCharacters(in: .whitespaces)
        if c == "`", info.contains("`") { return nil }
        return Fence(char: c, count: n, info: info)
    }

    static func atxHeading(_ t: MDLine) -> (Int, String)? {
        var n = 0
        while n < t.s.count, t.s[n] == "#" { n += 1 }
        guard (1...6).contains(n), n == t.s.count || t.s[n] == " " || t.s[n] == "\t" else { return nil }
        var body = t.string(n..<t.s.count).trimmingCharacters(in: .whitespaces)
        // Closing sequence: spaces then #s at the end.
        if let r = body.range(of: "#+$", options: .regularExpression) {
            let before = body[..<r.lowerBound]
            if before.isEmpty || before.hasSuffix(" ") || before.hasSuffix("\t") {
                body = String(before).trimmingCharacters(in: .whitespaces)
            }
        }
        return (n, body)
    }

    static func isRule(_ t: MDLine) -> Bool {
        guard let c = t.s.first, c == "-" || c == "*" || c == "_" else { return false }
        var n = 0
        for x in t.s {
            if x == c { n += 1 } else if x != " " && x != "\t" { return false }
        }
        return n >= 3
    }

    static func setextLevel(_ t: MDLine) -> Int? {
        guard let c = t.s.first, c == "=" || c == "-" else { return nil }
        var i = 0
        while i < t.s.count, t.s[i] == c { i += 1 }
        while i < t.s.count, t.s[i] == " " || t.s[i] == "\t" { i += 1 }
        guard i == t.s.count else { return nil }
        return c == "=" ? 1 : 2
    }

    struct Marker { var ordered: Bool; var delim: Unicode.Scalar; var number: Int; var marker: String; var width: Int; var first: MDLine }
    /// A list item marker at the start of `t` (indentation removed).
    static func listMarker(_ t: MDLine, interruptsParagraph: Bool) -> Marker? {
        guard let c = t.s.first else { return nil }
        var markerLen = 0
        var ordered = false, number = 1, delim = c
        if c == "-" || c == "+" || c == "*" {
            markerLen = 1
        } else if c.properties.numericType != nil, ("0"..."9").contains(c) {
            var j = 0
            while j < t.s.count, j < 10, ("0"..."9").contains(t.s[j]) { j += 1 }
            guard j <= 9, j < t.s.count, t.s[j] == "." || t.s[j] == ")" else { return nil }
            number = Int(t.string(0..<j)) ?? 1
            delim = t.s[j]
            ordered = true
            markerLen = j + 1
        } else { return nil }
        let rest = MDLine(scalars: Array(t.s[markerLen...]))
        if !rest.s.isEmpty, rest.s[0] != " ", rest.s[0] != "\t" { return nil }
        if interruptsParagraph {
            if rest.isBlank { return nil }
            if ordered, number != 1 { return nil }
        }
        // Content indent: marker + 1..4 spaces; 5 or more means 1 (the rest is indented code).
        // Columns are counted from the marker's end; tabs stop relative to the line start.
        var sp = rest.isBlank ? 1 : rest.indent
        if sp > 4 { sp = 1 }
        if sp < 1 { sp = 1 }
        let first = rest.isBlank ? MDLine(scalars: []) : rest.dropping(cols: sp)
        return Marker(ordered: ordered, delim: delim, number: number, marker: t.string(0..<markerLen), width: markerLen + sp, first: first)
    }

    /// Whether a line (indentation removed) starts a block that ends a paragraph.
    static func startsBlock(_ t: MDLine, interrupting: Bool = true) -> Bool {
        if fence(t) != nil || atxHeading(t) != nil || isRule(t) || t.s.first == ">" { return true }
        return listMarker(t, interruptsParagraph: interrupting) != nil
    }

    static func taskPrefix(_ p: MDText) -> (Bool, MDText)? {
        let u = Array(p.string.utf16)
        guard u.count >= 3, u[0] == 91, u[2] == 93, u.count == 3 || u[3] == 32 || u[3] == 9 || u[3] == 10 else { return nil }
        let checked: Bool
        switch u[1] { case 32: checked = false; case 120, 88: checked = true; default: return nil }
        let cut = min(u.count, 4)
        var rest = MDText()
        rest.string = String(utf16CodeUnits: Array(u[cut...]), count: u.count - cut)
        rest.spans = p.spans.compactMap { s in
            let lo = max(s.location, cut), hi = s.location + s.length
            guard hi > lo else { return nil }
            return MDSpan(location: lo - cut, length: hi - lo, style: s.style, link: s.link)
        }
        return (checked, rest)
    }

    // MARK: Tables

    static func splitRow(_ line: MDLine) -> [String] {
        var t = line.dropping(cols: line.indent).s
        while let l = t.last, l == " " || l == "\t" { t.removeLast() }
        var cells: [String] = []
        var cur = String.UnicodeScalarView()
        var i = 0
        if t.first == "|" { i = 1 }
        var ticks = 0           // open code span's backtick count
        while i < t.count {
            let c = t[i]
            if c == "\\", i + 1 < t.count, t[i + 1] == "|" { cur.append("|"); i += 2; continue }
            if c == "\\", i + 1 < t.count { cur.append(c); cur.append(t[i + 1]); i += 2; continue }
            if c == "`" {
                var n = 0
                while i + n < t.count, t[i + n] == "`" { n += 1 }
                if ticks == 0 { if hasClosingTicks(t, from: i + n, count: n) { ticks = n } }
                else if n == ticks { ticks = 0 }
                for _ in 0..<n { cur.append("`") }
                i += n; continue
            }
            if c == "|", ticks == 0 {
                cells.append(String(cur).trimmingCharacters(in: .whitespaces)); cur = .init(); i += 1
                continue
            }
            cur.append(c); i += 1
        }
        let last = String(cur).trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || t.last != "|" || (t.count >= 2 && t[t.count - 2] == "\\") { cells.append(last) }
        return cells
    }
    private static func hasClosingTicks(_ t: [Unicode.Scalar], from: Int, count: Int) -> Bool {
        var i = from
        while i < t.count {
            if t[i] == "`" {
                var n = 0
                while i + n < t.count, t[i + n] == "`" { n += 1 }
                if n == count { return true }
                i += n
            } else { i += 1 }
        }
        return false
    }

    static func delimiterRow(_ line: MDLine) -> [MDAlign]? {
        guard line.indent < 4 else { return nil }
        let t = line.dropping(cols: line.indent)
        guard t.s.contains("-"), t.s.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " || $0 == "\t" }) else { return nil }
        let cells = splitRow(line)
        guard !cells.isEmpty else { return nil }
        var aligns: [MDAlign] = []
        for c in cells {
            let s = c.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, s.allSatisfy({ $0 == "-" || $0 == ":" }), s.contains("-") else { return nil }
            let core = s.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            let l = s.hasPrefix(":"), r = s.hasSuffix(":")
            aligns.append(l && r ? .center : r ? .right : l ? .left : .none)
        }
        // A single column needs a pipe (else "---" is a setext underline or a rule).
        if cells.count == 1, !t.s.contains("|") { return nil }
        return aligns
    }

    static func table(_ lines: [MDLine], at i: Int, _ known: MDRefs?) -> (table: MDTable, end: Int)? {
        guard i + 1 < lines.count else { return nil }
        let h = lines[i]
        guard h.indent < 4, h.s.contains("|"), let aligns = delimiterRow(lines[i + 1]) else { return nil }
        let header = splitRow(h)
        guard header.count == aligns.count else { return nil }
        var rows: [[MDText]] = []
        var cols = aligns.count
        var j = i + 2
        while j < lines.count {
            let l = lines[j]
            if l.isBlank || (l.indent < 4 && startsBlock(l.dropping(cols: l.indent))) { break }
            let cells = splitRow(l).map { MDInlineParser.parse($0, breaks: false, refs: known) }
            cols = max(cols, cells.count)
            rows.append(cells)
            j += 1
        }
        // Rows keep every cell: missing cells are empty, extra cells add columns (no data lost).
        var al = aligns
        while al.count < cols { al.append(.none) }
        var head = header.map { MDInlineParser.parse($0, breaks: false, refs: known) }
        while head.count < cols { head.append(MDText()) }
        rows = rows.map { r in r + Array(repeating: MDText(), count: cols - r.count) }
        return (MDTable(aligns: al, header: head, rows: rows), j)
    }

    // MARK: Link reference definitions

    /// Removes leading `[label]: dest "title"` definitions from a paragraph's text.
    static func definitions(_ text: String, into refs: inout MDRefs) -> String {
        guard text.hasPrefix("[") else { return text }
        var rest = Substring(text)
        while rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]"), rest.index(after: close) < rest.endIndex,
                  rest[rest.index(after: close)] == ":" else { break }
            let label = String(rest[rest.index(after: rest.startIndex)..<close])
            guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !label.contains("[") else { break }
            var j = rest.index(close, offsetBy: 2)
            while j < rest.endIndex, rest[j] == " " || rest[j] == "\t" || rest[j] == "\n" { j = rest.index(after: j) }
            var dest = ""
            if j < rest.endIndex, rest[j] == "<" {
                guard let e = rest[j...].firstIndex(of: ">") else { break }
                dest = String(rest[rest.index(after: j)..<e]); j = rest.index(after: e)
            } else {
                let e = rest[j...].firstIndex { $0 == " " || $0 == "\n" || $0 == "\t" } ?? rest.endIndex
                dest = String(rest[j..<e]); j = e
            }
            guard !dest.isEmpty else { break }
            // Optional title on the same line; then the line must end.
            var title: String?
            var k = j
            while k < rest.endIndex, rest[k] == " " || rest[k] == "\t" { k = rest.index(after: k) }
            if k < rest.endIndex, let q = rest[k] == "\"" ? Character("\"") : rest[k] == "'" ? Character("'") : rest[k] == "(" ? Character(")") : nil {
                if let e = rest[rest.index(after: k)...].firstIndex(of: q) {
                    title = String(rest[rest.index(after: k)..<e]); k = rest.index(after: e)
                }
            }
            while k < rest.endIndex, rest[k] == " " || rest[k] == "\t" { k = rest.index(after: k) }
            guard k == rest.endIndex || rest[k] == "\n" else { break }
            let key = MDRefs.normalize(label)
            if refs.map[key] == nil { refs.map[key] = (MDInlineParser.unescape(dest), title) }
            rest = k == rest.endIndex ? "" : rest[rest.index(after: k)...]
        }
        return String(rest)
    }

}

// MARK: - Inlines

/// CommonMark inline parsing: code spans, escapes, entities, autolinks (angle and
/// GFM extended, recognised before emphasis so `_` in a URL is never emphasis),
/// links and images with the bracket stack, then emphasis and strikethrough with
/// the delimiter-run algorithm (flanking rules, rule of 3, openers bottom).
enum MDInlineParser {
    private enum Node {
        case text(String)
        case styled(String, MDStyle, String?)     // code, autolink, image placeholder
        case delim(Unicode.Scalar, count: Int)
        case open(MDStyle)
        case close(MDStyle)
        case linkOpen(String)
        case linkClose
        case br
    }
    private struct Delim {
        var node: Int
        var char: Unicode.Scalar
        var count: Int
        var origCount: Int
        var canOpen: Bool
        var canClose: Bool
        var active = true
    }
    private struct Bracket { var node: Int; var image: Bool; var active: Bool; var delimBottom: Int; var pos: Int }

    static func parse(_ s: String, breaks: Bool = true, refs: MDRefs? = nil) -> MDText {
        let src = Array(s.unicodeScalars)
        var nodes: [Node] = []
        var delims: [Delim] = []
        var brackets: [Bracket] = []
        var text = String.UnicodeScalarView()
        var i = 0
        func flush() { if !text.isEmpty { nodes.append(.text(String(text))); text = .init() } }
        func prev(_ i: Int) -> Unicode.Scalar? { i > 0 ? src[i - 1] : nil }

        while i < src.count {
            let c = src[i]
            switch c {
            case "\\":
                if i + 1 < src.count, isASCIIPunct(src[i + 1]) { text.append(src[i + 1]); i += 2; continue }
                if i + 1 < src.count, src[i + 1] == "\n" { flush(); nodes.append(.br); i += 2; continue }
                text.append(c); i += 1
            case "`":
                var n = 0
                while i + n < src.count, src[i + n] == "`" { n += 1 }
                if let end = closingTicks(src, from: i + n, count: n) {
                    flush()
                    var body = String.UnicodeScalarView()
                    for x in src[(i + n)..<end] { body.append(x == "\n" ? " " : x) }
                    var code = String(body)
                    if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    nodes.append(.styled(code, .code, nil))
                    i = end + n
                } else {
                    for _ in 0..<n { text.append("`") }
                    i += n
                }
            case "&":
                if let (rep, len) = entity(src, i) { text.append(contentsOf: rep.unicodeScalars); i += len } else { text.append(c); i += 1 }
            case "<":
                if let (url, len, label) = angleAutolink(src, i) {
                    flush(); nodes.append(.styled(label, .link, url)); i += len
                } else { text.append(c); i += 1 }
            case "\n":
                flush()
                if breaks { nodes.append(.br) } else { text.append(" ") }
                i += 1
                while i < src.count, src[i] == " " || src[i] == "\t" { i += 1 }
            case "*", "_", "~":
                var n = 0
                while i + n < src.count, src[i + n] == c { n += 1 }
                if c == "~", n > 2 { for _ in 0..<n { text.append(c) }; i += n; continue }
                let before = prev(i), after: Unicode.Scalar? = i + n < src.count ? src[i + n] : nil
                let bWS = before.map(isWS) ?? true, aWS = after.map(isWS) ?? true
                let bP = before.map(isPunct) ?? false, aP = after.map(isPunct) ?? false
                let left = !aWS && (!aP || bWS || bP)
                let right = !bWS && (!bP || aWS || aP)
                var canOpen = left, canClose = right
                if c == "_" { canOpen = left && (!right || bP); canClose = right && (!left || aP) }
                flush()
                nodes.append(.delim(c, count: n))
                if canOpen || canClose {
                    delims.append(Delim(node: nodes.count - 1, char: c, count: n, origCount: n, canOpen: canOpen, canClose: canClose))
                }
                i += n
            case "!" where i + 1 < src.count && src[i + 1] == "[":
                flush()
                nodes.append(.text("!["))
                brackets.append(Bracket(node: nodes.count - 1, image: true, active: true, delimBottom: delims.count, pos: i + 2))
                i += 2
            case "[":
                flush()
                nodes.append(.text("["))
                brackets.append(Bracket(node: nodes.count - 1, image: false, active: true, delimBottom: delims.count, pos: i + 1))
                i += 1
            case "]":
                guard let b = brackets.popLast() else { text.append(c); i += 1; continue }
                guard b.active else { text.append(c); i += 1; continue }
                flush()
                var dest: String?, end = i + 1
                if let (d, _, e) = inlineLinkTail(src, i + 1) { dest = d; end = e }
                else if let refs {
                    // [text][label], [text][], [text]
                    let inner = String(String.UnicodeScalarView(src[b.pos..<i]))
                    if i + 1 < src.count, src[i + 1] == "[", let close = src[(i + 2)...].firstIndex(of: "]") {
                        let label = String(String.UnicodeScalarView(src[(i + 2)..<close]))
                        let key = MDRefs.normalize(label.isEmpty ? inner : label)
                        if let r = refs.map[key] { dest = r.0; end = close + 1 }
                    } else if let r = refs.map[MDRefs.normalize(inner)] { dest = r.0 }
                }
                guard let dest else { text.append(c); i += 1; continue }
                // Emphasis inside the link text, then wrap it.
                processEmphasis(&nodes, &delims, bottom: b.delimBottom)
                if b.image {
                    // The alt text, plain; shown as a link placeholder (never loaded).
                    let alt = plain(nodes[(b.node + 1)...])
                    nodes.removeSubrange(b.node...)
                    nodes.append(.styled(alt.isEmpty ? dest : alt, [.image, .link], dest))
                    brackets.removeAll { $0.node > b.node }
                } else {
                    nodes[b.node] = .linkOpen(dest)
                    nodes.append(.linkClose)
                    // No links inside links.
                    brackets.removeAll { $0.node > b.node }
                    for k in brackets.indices where !brackets[k].image { brackets[k].active = false }
                }
                i = end
            default:
                // GFM extended autolinks at a word start: www., http://, https://, mailto-less emails.
                if (c == "w" || c == "h" || c == "W" || c == "H"), prev(i).map({ isWS($0) || $0 == "(" || $0 == "*" || $0 == "_" || $0 == "~" || $0 == "\"" || $0 == "'" }) ?? true,
                   let (url, len) = extendedAutolink(src, i) {
                    flush()
                    nodes.append(.styled(String(String.UnicodeScalarView(src[i..<(i + len)])), .link, url))
                    i += len
                    continue
                }
                if c == "@", let (start, len) = emailAutolink(src, i, textTail: text) {
                    // Pull the local part back out of the pending text.
                    let local = Array(text)
                    let keep = local.count - start
                    var t2 = String.UnicodeScalarView(); t2.append(contentsOf: local[0..<keep])
                    let addr = String(String.UnicodeScalarView(local[keep...])) + String(String.UnicodeScalarView(src[i..<(i + len)]))
                    text = t2
                    flush()
                    nodes.append(.styled(addr, .link, "mailto:" + addr))
                    i += len
                    continue
                }
                text.append(c); i += 1
            }
        }
        flush()
        processEmphasis(&nodes, &delims, bottom: 0)
        var out = flatten(nodes)
        // Trailing spaces of a line are not drawn (hard breaks are "\n").
        return trimLineEnds(&out)
    }

    // MARK: Emphasis

    private static func processEmphasis(_ nodes: inout [Node], _ delims: inout [Delim], bottom: Int) {
        // Openers bottom per (char, closer can open, closer count % 3).
        var bottoms: [String: Int] = [:]
        var ci = bottom
        while ci < delims.count {
            let closer = delims[ci]
            guard closer.canClose, closer.count > 0 else { ci += 1; continue }
            let key = "\(closer.char)\(closer.canOpen)\(closer.origCount % 3)"
            let floor = max(bottom, bottoms[key] ?? bottom)
            var oi = ci - 1
            var found = -1
            while oi >= floor {
                let o = delims[oi]
                if o.char == closer.char, o.canOpen, o.count > 0 {
                    if closer.char == "~" {
                        if o.count == closer.count { found = oi; break }
                    } else {
                        let odd = (o.canClose || closer.canOpen) && (o.origCount + closer.origCount) % 3 == 0
                            && !(o.origCount % 3 == 0 && closer.origCount % 3 == 0)
                        if !odd { found = oi; break }
                    }
                }
                oi -= 1
            }
            if found < 0 {
                bottoms[key] = ci
                ci += 1
                continue
            }
            let use: Int
            let style: MDStyle
            if closer.char == "~" { use = closer.count; style = .strike }
            else { use = delims[found].count >= 2 && closer.count >= 2 ? 2 : 1; style = use == 2 ? .strong : .emphasis }
            delims[found].count -= use
            delims[ci].count -= use
            // Marks: inner first. After the opener's node, before the closer's node.
            insertMark(&nodes, &delims, after: delims[found].node, .open(style))
            insertMark(&nodes, &delims, before: delims[ci].node, .close(style))
            // Delimiters between them are literal.
            for k in (found + 1)..<ci { delims[k].canOpen = false; delims[k].canClose = false }
            if delims[found].count == 0 { delims[found].canOpen = false }
            if delims[ci].count == 0 { ci += 1 }
        }
        // What matching left of each run prints as literal characters.
        for d in delims[min(bottom, delims.count)...] { nodes[d.node] = .delim(d.char, count: d.count) }
        delims.removeSubrange(min(bottom, delims.count)...)
    }

    /// Inserting a node shifts every later delimiter's node index.
    private static func insertMark(_ nodes: inout [Node], _ delims: inout [Delim], after n: Int, _ m: Node) {
        nodes.insert(m, at: n + 1)
        for k in delims.indices where delims[k].node > n { delims[k].node += 1 }
    }
    private static func insertMark(_ nodes: inout [Node], _ delims: inout [Delim], before n: Int, _ m: Node) {
        nodes.insert(m, at: n)
        for k in delims.indices where delims[k].node >= n { delims[k].node += 1 }
    }

    // MARK: Flatten

    private static func flatten(_ nodes: [Node]) -> MDText {
        var out = String.UnicodeScalarView()
        var spans: [MDSpan] = []
        var style: MDStyle = []
        var counts: [MDStyle: Int] = [:]
        var links: [String] = []
        var len16 = 0
        var runStart = 0
        var runStyle: MDStyle = []
        var runLink: String?
        func cut() {
            if len16 > runStart, !runStyle.isEmpty || runLink != nil {
                spans.append(MDSpan(location: runStart, length: len16 - runStart, style: runStyle, link: runLink))
            }
            runStart = len16
        }
        func set(_ s: MDStyle, _ l: String?) { if s != runStyle || l != runLink { cut(); runStyle = s; runLink = l } }
        func emit(_ s: String) { for u in s.unicodeScalars { out.append(u); len16 += u.utf16.count } }
        for n in nodes {
            // cmux: a refused destination is "" on the stack and plain text (MarkdownLinkPolicy).
            let linkNow = links.last { !$0.isEmpty }
            switch n {
            case let .text(s): set(style, linkNow); emit(s)
            case let .styled(s, st, l) where l.map(MarkdownLinkPolicy.allows) == false:
                set(style.union(st).subtracting([.link, .image]), linkNow); emit(s)
            case let .styled(s, st, l): set(style.union(st), l ?? linkNow); emit(s)
            case let .delim(ch, count):
                if count > 0 { set(style, linkNow); emit(String(repeating: String(ch), count: count)) }
            case let .open(s): counts[s, default: 0] += 1; style.insert(s)
            case let .close(s): counts[s, default: 0] -= 1; if counts[s, default: 0] <= 0 { style.remove(s) }
            case let .linkOpen(d):
                let allowed = MarkdownLinkPolicy.allows(d)
                links.append(allowed ? d : "")
                if allowed { style.insert(.link) }
            case .linkClose: links.removeLast(); if !links.contains(where: { !$0.isEmpty }) { style.remove(.link) }
            case .br: set(style, linkNow); emit("\n")
            }
        }
        cut()
        return MDText(string: String(out), spans: merge(spans))
    }

    private static func merge(_ s: [MDSpan]) -> [MDSpan] {
        var out: [MDSpan] = []
        for x in s {
            if var l = out.last, l.location + l.length == x.location, l.style == x.style, l.link == x.link {
                l.length += x.length; out[out.count - 1] = l
            } else { out.append(x) }
        }
        return out
    }

    private static func trimLineEnds(_ t: inout MDText) -> MDText {
        guard t.string.contains(" \n") || t.string.hasSuffix(" ") || t.string.hasPrefix(" ") else { return t }
        // Remove spaces before each "\n" and at both ends; remap spans.
        let u = Array(t.string.utf16)
        var keep = [Bool](repeating: true, count: u.count)
        var j = u.count - 1
        while j >= 0, u[j] == 32 { keep[j] = false; j -= 1 }
        var k = 0
        while k < u.count, u[k] == 32 { keep[k] = false; k += 1 }
        for x in u.indices where u[x] == 10 {
            var y = x - 1
            while y >= 0, u[y] == 32 { keep[y] = false; y -= 1 }
        }
        var map = [Int](repeating: 0, count: u.count + 1)
        var out: [UInt16] = []
        for x in u.indices { map[x] = out.count; if keep[x] { out.append(u[x]) } }
        map[u.count] = out.count
        let spans = t.spans.compactMap { s -> MDSpan? in
            let a = map[s.location], b = map[s.location + s.length]
            return b > a ? MDSpan(location: a, length: b - a, style: s.style, link: s.link) : nil
        }
        return MDText(string: String(utf16CodeUnits: out, count: out.count), spans: spans)
    }

    private static func plain(_ ns: ArraySlice<Node>) -> String {
        var s = ""
        for n in ns {
            switch n {
            case let .text(t): s += t
            case let .styled(t, _, _): s += t
            case let .delim(c, n): s += String(repeating: String(c), count: n)
            case .br: s += " "
            default: break
            }
        }
        return s
    }

    // MARK: Pieces

    static func isASCIIPunct(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v)
    }
    static func isWS(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\r" || c.properties.isWhitespace }
    static func isPunct(_ c: Unicode.Scalar) -> Bool {
        if isASCIIPunct(c) { return true }
        switch c.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return true
        default: return false
        }
    }

    private static func closingTicks(_ s: [Unicode.Scalar], from: Int, count: Int) -> Int? {
        var i = from
        while i < s.count {
            if s[i] == "`" {
                var n = 0
                while i + n < s.count, s[i + n] == "`" { n += 1 }
                if n == count { return i }
                i += n
            } else { i += 1 }
        }
        return nil
    }

    static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "bull": "•", "middot": "·", "times": "×", "divide": "÷", "deg": "°", "plusmn": "±", "larr": "←", "rarr": "→",
        "uarr": "↑", "darr": "↓", "harr": "↔", "check": "✓", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§",
        "para": "¶", "laquo": "«", "raquo": "»", "le": "≤", "ge": "≥", "ne": "≠", "infin": "∞",
    ]
    private static func entity(_ s: [Unicode.Scalar], _ i: Int) -> (String, Int)? {
        guard let semi = s[(i + 1)...].prefix(34).firstIndex(of: ";") else { return nil }
        let body = String(String.UnicodeScalarView(s[(i + 1)..<semi]))
        if body.hasPrefix("#") {
            let hex = body.hasPrefix("#x") || body.hasPrefix("#X")
            let digits = body.dropFirst(hex ? 2 : 1)
            guard !digits.isEmpty, digits.count <= (hex ? 6 : 7), let v = UInt32(digits, radix: hex ? 16 : 10) else { return nil }
            let scalar = (v == 0 || v > 0x10FFFF) ? Unicode.Scalar(0xFFFD)! : (Unicode.Scalar(v) ?? Unicode.Scalar(0xFFFD)!)
            return (String(scalar), semi - i + 1)
        }
        guard let r = entities[body] else { return nil }
        return (r, semi - i + 1)
    }

    private static func angleAutolink(_ s: [Unicode.Scalar], _ i: Int) -> (String, Int, String)? {
        guard let end = s[(i + 1)...].prefix(2048).firstIndex(of: ">") else { return nil }
        let body = String(String.UnicodeScalarView(s[(i + 1)..<end]))
        guard !body.isEmpty, !body.contains(where: { $0 == " " || $0 == "<" || $0 == "\n" }) else { return nil }
        if let colon = body.firstIndex(of: ":") {
            let scheme = body[..<colon]
            guard (2...32).contains(scheme.count), scheme.first!.isLetter,
                  scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }) else { return nil }
            return (body, end - i + 1, body)
        }
        if body.contains("@"), body.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"#, options: .regularExpression) != nil {
            return ("mailto:" + body, end - i + 1, body)
        }
        return nil
    }

    /// GFM extended autolink at `i`: "www." or "http(s)://", a valid domain, then
    /// anything up to whitespace or "<", minus trailing punctuation, an unbalanced
    /// ")" and a trailing entity-like "&x;".
    static func extendedAutolink(_ s: [Unicode.Scalar], _ i: Int) -> (String, Int)? {
        func has(_ p: String) -> Bool {
            let u = Array(p.unicodeScalars)
            guard i + u.count <= s.count else { return false }
            for k in u.indices where Character(s[i + k]).lowercased() != Character(u[k]).lowercased() { return false }
            return true
        }
        var start = i
        var prefix = ""
        if has("https://") { start += 8 } else if has("http://") { start += 7 } else if has("www.") { prefix = "http://" } else { return nil }
        // Domain: alphanumerics, "-", "_", "." ; at least one "."; no "_" in the last two labels.
        var j = start
        while j < s.count, s[j].properties.isAlphabetic || ("0"..."9").contains(s[j]) || s[j] == "-" || s[j] == "_" || s[j] == "." { j += 1 }
        let domain = String(String.UnicodeScalarView(s[start..<j]))
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        let port = j < s.count && s[j] == ":"
        guard !domain.isEmpty, !domain.hasPrefix("."), !labels.suffix(2).contains(where: { $0.contains("_") }) else { return nil }
        if labels.count < 2 || labels.last!.isEmpty {
            // "www." needs a real domain; "http://" also takes localhost and a host with a port.
            guard prefix.isEmpty, domain == "localhost" || port else { return nil }
        }
        while j < s.count, !isWS(s[j]), s[j] != "<" { j += 1 }
        var end = j
        // Trailing punctuation and unbalanced parentheses.
        while end > start {
            let c = s[end - 1]
            if "?!.,:*_~'\"".unicodeScalars.contains(c) { end -= 1; continue }
            if c == ")" {
                var open = 0, close = 0
                for k in i..<end { if s[k] == "(" { open += 1 } else if s[k] == ")" { close += 1 } }
                if close > open { end -= 1; continue }
            }
            if c == ";" {
                var k = end - 2
                while k > start, s[k].properties.isAlphabetic || ("0"..."9").contains(s[k]) { k -= 1 }
                if k >= start, s[k] == "&" { end = k; continue }
            }
            break
        }
        guard end > start else { return nil }
        let raw = String(String.UnicodeScalarView(s[i..<end]))
        return (prefix + raw, end - i)
    }

    /// An email at "@" position `i`: the local part is the tail of the pending text.
    private static func emailAutolink(_ s: [Unicode.Scalar], _ i: Int, textTail: String.UnicodeScalarView) -> (Int, Int)? {
        let tail = Array(textTail)
        var k = tail.count
        while k > 0, tail[k - 1].properties.isAlphabetic || ("0"..."9").contains(tail[k - 1]) || ".-_+".unicodeScalars.contains(tail[k - 1]) { k -= 1 }
        let localLen = tail.count - k
        guard localLen > 0, k == 0 || isWS(tail[k - 1]) || tail[k - 1] == "(" else { return nil }
        var j = i + 1
        while j < s.count, s[j].properties.isAlphabetic || ("0"..."9").contains(s[j]) || s[j] == "-" || s[j] == "_" || s[j] == "." { j += 1 }
        while j > i + 1, s[j - 1] == "." || s[j - 1] == "-" || s[j - 1] == "_" { j -= 1 }
        let domain = String(String.UnicodeScalarView(s[(i + 1)..<j]))
        guard domain.contains("."), !domain.hasPrefix("."), let last = domain.split(separator: ".").last,
              !last.contains("_"), last.count >= 2 else { return nil }
        return (localLen, j - i)
    }

    /// `(dest "title")` after "]". Returns (dest, title, index after ")").
    private static func inlineLinkTail(_ s: [Unicode.Scalar], _ i: Int) -> (String, String?, Int)? {
        guard i < s.count, s[i] == "(" else { return nil }
        var j = i + 1
        func ws() { while j < s.count, s[j] == " " || s[j] == "\t" || s[j] == "\n" { j += 1 } }
        ws()
        var dest = String.UnicodeScalarView()
        if j < s.count, s[j] == "<" {
            j += 1
            while j < s.count, s[j] != ">", s[j] != "\n" {
                if s[j] == "\\", j + 1 < s.count, isASCIIPunct(s[j + 1]) { dest.append(s[j + 1]); j += 2; continue }
                dest.append(s[j]); j += 1
            }
            guard j < s.count, s[j] == ">" else { return nil }
            j += 1
        } else {
            var depth = 0
            while j < s.count, !isWS(s[j]), s[j].value >= 32 {
                if s[j] == "\\", j + 1 < s.count, isASCIIPunct(s[j + 1]) { dest.append(s[j + 1]); j += 2; continue }
                if s[j] == "(" { depth += 1 }
                if s[j] == ")" { if depth == 0 { break }; depth -= 1 }
                dest.append(s[j]); j += 1
            }
            guard depth == 0 else { return nil }
        }
        ws()
        var title: String?
        if j < s.count, let q: Unicode.Scalar = s[j] == "\"" ? "\"" : s[j] == "'" ? "'" : s[j] == "(" ? ")" : nil {
            var t = String.UnicodeScalarView()
            j += 1
            while j < s.count, s[j] != q {
                if s[j] == "\\", j + 1 < s.count, isASCIIPunct(s[j + 1]) { t.append(s[j + 1]); j += 2; continue }
                t.append(s[j]); j += 1
            }
            guard j < s.count else { return nil }
            j += 1
            title = String(t)
            ws()
        }
        guard j < s.count, s[j] == ")" else { return nil }
        return (String(dest), title, j + 1)
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = String.UnicodeScalarView()
        let u = Array(s.unicodeScalars)
        var i = 0
        while i < u.count {
            if u[i] == "\\", i + 1 < u.count, isASCIIPunct(u[i + 1]) { out.append(u[i + 1]); i += 2 } else { out.append(u[i]); i += 1 }
        }
        return String(out)
    }
}
