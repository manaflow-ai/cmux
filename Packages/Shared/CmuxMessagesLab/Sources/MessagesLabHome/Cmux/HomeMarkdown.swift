import Foundation

/// An agent's Markdown as MessagesLab text: the shown text without markers
/// and the style and link runs MessagesLab's `TextLayout` measures and draws
/// (bold, italic, strikethrough, inline code and code blocks, links).
///
/// A safe subset, line by line: fenced code blocks (fences dropped, lines
/// monospaced), `#` headings (bold), `-`/`*`/`+` bullets (`•`), numbered
/// items (kept), and inline `**bold**`/`__bold__`, `*italic*`/`_italic_`,
/// `~~strike~~`, `` `code` ``, `[label](url)` and `<url>`. Only http, https
/// and mailto URLs, a cmux app link (URL.isCmuxAppLink) and a path
/// (URL.isHomePathLink) become links; another scheme shows its label as text.
/// Bare paths, cmux ids and web URLs in plain text (or a whole code span)
/// link too (HomeAutoLinks).
/// Anything else (HTML, tables, images) stays as written. Offsets are UTF-16,
/// like MessagesLab's runs.
enum HomeMarkdown {
    /// `chips`: links to cmux objects, files and GitHub objects show as chips (HomeLinkChip):
    /// the transcript passes true; a plain-text use (the sidebar preview) keeps the default.
    static func render(_ source: String, chips: Bool = false) -> (text: String, runs: [TextRun]) {
        var pass = Pass(chips: chips)
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) { pass.line(raw) }
        return (pass.out.text, pass.out.runs)
    }

    /// One left-to-right pass over a source, line by line: the only state a line hands the next
    /// is whether a code fence is open (and whether a line came before), so a pass stopped after
    /// any line resumes exactly (HomeMarkdownRenderer: a streaming reply renders only its new lines).
    struct Pass {
        var out = Output()
        var inFence = false
        var first = true

        init(chips: Bool = false) { out.chips = chips }

        /// Renders one source line (no newline). `lines`: rendered lines outside a fence, by
        /// their source (the renderer's cache); nil renders every line.
        mutating func line(_ raw: Substring, lines: HomeMarkdownLineCache? = nil) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return
            }
            if !first { out.append("\n", []) }
            first = false
            if inFence {
                out.append(String(raw), raw.isEmpty ? [] : ["code"])
                return
            }
            if let lines {
                out.append(lines.rendered(raw))
            } else {
                HomeMarkdown.renderLine(String(raw), into: &out)
            }
        }
    }

    /// One line outside a code fence: heading, bullet, numbered item or paragraph text.
    static func renderLine(_ line: String, into out: inout Output) {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let body = Substring(line.dropFirst(indent.count))
        let pad = String(repeating: "   ", count: min(4, indent.count / 2))
        if let (level, rest) = heading(body), level > 0 {
            Inline.parse(Array(rest), into: &out, styles: ["bold"], link: nil)
        } else if let rest = bullet(body) {
            out.append(pad + "• ", [])
            Inline.parse(Array(rest), into: &out, styles: [], link: nil)
        } else if let (number, rest) = numbered(body) {
            out.append(pad + number + " ", [])
            Inline.parse(Array(rest), into: &out, styles: [], link: nil)
        } else {
            out.append(String(indent), [])
            Inline.parse(Array(body), into: &out, styles: [], link: nil)
        }
    }

    private static func heading(_ s: Substring) -> (Int, Substring)? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return (hashes, s.dropFirst(hashes + 1))
    }

    private static func bullet(_ s: Substring) -> Substring? {
        guard let c = s.first, c == "-" || c == "*" || c == "+", s.dropFirst().first == " " else { return nil }
        let rest = s.dropFirst(2)
        // "- - -" and "* * *" are rules, not items.
        if rest.allSatisfy({ $0 == c || $0 == " " }), rest.contains(c) { return nil }
        return rest
    }

    private static func numbered(_ s: Substring) -> (String, Substring)? {
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard (1...4).contains(digits.count) else { return nil }
        let after = s.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
        return (digits + ".", after.dropFirst(2))
    }

    /// The shown text and its runs, built left to right.
    struct Output {
        var text = ""
        var runs: [TextRun] = []
        private var length = 0
        /// Whether chip links (HomeLinkChip) show as chips.
        var chips = false

        mutating func append(_ s: String, _ styles: [String], link: String? = nil) {
            guard !s.isEmpty else { return }
            if chips, let link, let kind = HomeLinkChip.kind(for: link) {
                // A chip: its first piece starts with the icon's pad; its label wraps as one unit.
                let starts = runs.last.map { $0.link != link || $0.start + $0.length != length } ?? true
                let label = HomeLinkChip.label(s)
                return appendRun(starts ? String(HomeLinkChip.pad) + label : label, styles + [HomeLinkChip.stylePrefix + kind.rawValue], link: link)
            }
            appendRun(s, styles, link: link)
        }

        private mutating func appendRun(_ s: String, _ styles: [String], link: String?) {
            let n = (s as NSString).length
            if !styles.isEmpty || link != nil {
                if let last = runs.last, last.start + last.length == length, last.style == (styles.isEmpty ? nil : styles), last.link == link {
                    runs.update(at: runs.count - 1) { $0.length += n } // crash program: checked
                } else {
                    runs.append(TextRun(start: length, length: n, style: styles.isEmpty ? nil : styles, link: link, mention: nil, detected: nil))
                }
            }
            text += s
            length += n
        }

        /// Appends a line rendered on its own (`renderLine` into an empty Output): its runs move by
        /// this text's length. A run never joins one before it: the line follows a newline (no run)
        /// or starts the text.
        mutating func append(_ line: Output) {
            guard !line.text.isEmpty else { return }
            runs.reserveCapacity(runs.count + line.runs.count)
            for var r in line.runs { r.start += length; runs.append(r) }
            text += line.text
            length += line.length
        }
    }

    enum Inline {
        static func parse(_ c: [Character], into out: inout Output, styles: [String], link: String?) {
            var i = 0
            var plain = ""
            // Plain text outside a link links its bare paths, cmux ids and web URLs (HomeAutoLinks).
            func flush() {
                if link == nil { out.appendLinkingBare(plain, styles) } else { out.append(plain, styles, link: link) }
                plain = ""
            }
            // Crash program: checked reads and clamped slices (agent text is external input).
            while i < c.count, let ch = c[checked: i] {
                if ch == "\\", i + 1 < c.count, let next = c[checked: i + 1], next.isASCII, next.isPunctuation || next.isSymbol {
                    plain.append(next); i += 2; continue
                }
                if ch == "`" {
                    let ticks = run(c, i, "`")
                    if let close = find(c, from: i + ticks, String(repeating: "`", count: ticks)) {
                        var code = String(c.slice(i + ticks, close))
                        if code.count > 2, code.first == " ", code.last == " " { code = String(code.dropFirst().dropLast()) }
                        flush()
                        // A code span that is one whole path or cmux id (`~/a.md`) links to it.
                        let whole = link == nil ? HomeMarkdown.autoLinks(in: code).first.flatMap {
                            $0.range == NSRange(location: 0, length: (code as NSString).length) ? $0 : nil
                        } : nil
                        out.append(whole?.label ?? code, add("code", to: styles), link: link ?? whole?.link)
                        i = close + ticks; continue
                    }
                    plain += String(repeating: "`", count: ticks); i += ticks; continue
                }
                if ch == "[", link == nil, let (label, url, end) = linkAt(c, i) {
                    flush()
                    parse(label, into: &out, styles: styles, link: safe(url))
                    i = end; continue
                }
                if ch == "<", link == nil, let close = c.slice(from: i + 1).firstIndex(of: ">") {
                    let url = String(c.slice(i + 1, close))
                    if let s = safe(url), !url.contains(" ") {
                        flush()
                        out.append(url, styles, link: s)
                        i = close + 1; continue
                    }
                }
                if ch == "*" || ch == "_" || ch == "~" {
                    let n = run(c, i, ch)
                    if let (style, width) = delimiter(ch, n), let close = closing(c, from: i, ch, width) {
                        flush()
                        parse(Array(c.slice(i + width, close)), into: &out, styles: add(style, to: styles), link: link)
                        i = close + width; continue
                    }
                    plain += String(repeating: String(ch), count: n); i += n; continue
                }
                plain.append(ch); i += 1
            }
            flush()
        }

        private static func add(_ s: String, to styles: [String]) -> [String] { styles.contains(s) ? styles : styles + [s] }

        private static func delimiter(_ ch: Character, _ n: Int) -> (String, Int)? {
            switch (ch, n) {
            case ("~", 2...): return ("strikethrough", 2)
            case ("~", _): return nil
            case (_, 2...): return ("bold", 2)
            default: return ("italic", 1)
            }
        }

        private static func run(_ c: [Character], _ i: Int, _ ch: Character) -> Int {
            var n = 0
            while i + n < c.count, c[checked: i + n] == ch { n += 1 }
            return n
        }

        private static func find(_ c: [Character], from: Int, _ s: String) -> Int? {
            let p = Array(s)
            var j = from
            while j + p.count <= c.count {
                if c.slice(j, j + p.count).elementsEqual(p), j + p.count == c.count || c[checked: j + p.count] != p.first { return j }
                j += 1
            }
            return nil
        }

        /// The closing delimiter of a span opened at `i`: content does not
        /// start or end with a space, and `_` spans sit on word boundaries
        /// (snake_case stays as written).
        private static func closing(_ c: [Character], from i: Int, _ ch: Character, _ width: Int) -> Int? {
            let start = i + width
            guard start < c.count, let first = c[checked: start], !first.isWhitespace else { return nil }
            if ch == "_", i > 0, let before = c[checked: i - 1], before.isLetter || before.isNumber { return nil }
            var j = start + 1
            while j + width <= c.count {
                if c.slice(j, j + width).allSatisfy({ $0 == ch }), c[checked: j - 1]?.isWhitespace == false {
                    let after = j + width
                    let longer = after < c.count && c[checked: after] == ch
                    let boundary = ch != "_" || after == c.count || !(c[checked: after].map { $0.isLetter || $0.isNumber } ?? false)
                    if !longer || width == 2, boundary, !(width == 1 && j + 1 < c.count && c[checked: j + 1] == ch) { return j }
                }
                j += 1
            }
            return nil
        }

        private static func linkAt(_ c: [Character], _ i: Int) -> ([Character], String, Int)? {
            var depth = 0
            var j = i
            while j < c.count {
                if c[checked: j] == "[" { depth += 1 } else if c[checked: j] == "]" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard j + 1 < c.count, c[checked: j + 1] == "(" else { return nil }
            var k = j + 2, parens = 1
            while k < c.count {
                if c[checked: k] == "(" { parens += 1 } else if c[checked: k] == ")" { parens -= 1; if parens == 0 { break } }
                k += 1
            }
            guard k < c.count else { return nil }
            let url = String(c.slice(j + 2, k)).trimmingCharacters(in: .whitespaces)
            return (Array(c.slice(i + 1, j)), url, k + 1)
        }

        /// The one link rule (MarkdownLinkPolicy: http, https, mailto, and Home's app forms,
        /// a cmux app link, URL.isCmuxAppLink, or a path, URL.isHomePathLink), so this renderer
        /// and MessagesLab's agree. A destination written as a path (`/Users/…`, `~/…`) or a bare
        /// cmux id becomes its link first (HomeMarkdown.destination).
        private static func safe(_ url: String) -> String? { HomeMarkdown.destination(url) }
    }
}
