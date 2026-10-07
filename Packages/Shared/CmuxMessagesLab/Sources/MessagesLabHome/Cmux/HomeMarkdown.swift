import Foundation

/// An agent's Markdown as MessagesLab text: the shown text without markers
/// and the style and link runs MessagesLab's `TextLayout` measures and draws
/// (bold, italic, strikethrough, inline code and code blocks, links).
///
/// A safe subset, line by line: fenced code blocks (fences dropped, lines
/// monospaced), `#` headings (bold), `-`/`*`/`+` bullets (`•`), numbered
/// items (kept), and inline `**bold**`/`__bold__`, `*italic*`/`_italic_`,
/// `~~strike~~`, `` `code` ``, `[label](url)` and `<url>`. Only http, https
/// and mailto URLs become links; another scheme shows its label as text.
/// Anything else (HTML, tables, images) stays as written. Offsets are UTF-16,
/// like MessagesLab's runs.
enum HomeMarkdown {
    static func render(_ source: String) -> (text: String, runs: [TextRun]) {
        var out = Output()
        var inFence = false
        var first = true
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if !first { out.append("\n", []) }
            first = false
            if inFence {
                out.append(line, line.isEmpty ? [] : ["code"])
                continue
            }
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
        return (out.text, out.runs)
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

        mutating func append(_ s: String, _ styles: [String], link: String? = nil) {
            guard !s.isEmpty else { return }
            let n = (s as NSString).length
            if !styles.isEmpty || link != nil {
                if let last = runs.last, last.start + last.length == length, last.style == (styles.isEmpty ? nil : styles), last.link == link {
                    runs[runs.count - 1].length += n
                } else {
                    runs.append(TextRun(start: length, length: n, style: styles.isEmpty ? nil : styles, link: link, mention: nil, detected: nil))
                }
            }
            text += s
            length += n
        }
    }

    enum Inline {
        static func parse(_ c: [Character], into out: inout Output, styles: [String], link: String?) {
            var i = 0
            var plain = ""
            func flush() { out.append(plain, styles, link: link); plain = "" }
            while i < c.count {
                let ch = c[i]
                if ch == "\\", i + 1 < c.count, c[i + 1].isASCII, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                    plain.append(c[i + 1]); i += 2; continue
                }
                if ch == "`" {
                    let ticks = run(c, i, "`")
                    if let close = find(c, from: i + ticks, String(repeating: "`", count: ticks)) {
                        var code = String(c[(i + ticks)..<close])
                        if code.count > 2, code.first == " ", code.last == " " { code = String(code.dropFirst().dropLast()) }
                        flush()
                        out.append(code, add("code", to: styles), link: link)
                        i = close + ticks; continue
                    }
                    plain += String(repeating: "`", count: ticks); i += ticks; continue
                }
                if ch == "[", link == nil, let (label, url, end) = linkAt(c, i) {
                    flush()
                    parse(label, into: &out, styles: styles, link: safe(url))
                    i = end; continue
                }
                if ch == "<", link == nil, let close = c[(i + 1)...].firstIndex(of: ">") {
                    let url = String(c[(i + 1)..<close])
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
                        parse(Array(c[(i + width)..<close]), into: &out, styles: add(style, to: styles), link: link)
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
            while i + n < c.count, c[i + n] == ch { n += 1 }
            return n
        }

        private static func find(_ c: [Character], from: Int, _ s: String) -> Int? {
            let p = Array(s)
            var j = from
            while j + p.count <= c.count {
                if Array(c[j..<(j + p.count)]) == p, j + p.count == c.count || c[j + p.count] != p[0] { return j }
                j += 1
            }
            return nil
        }

        /// The closing delimiter of a span opened at `i`: content does not
        /// start or end with a space, and `_` spans sit on word boundaries
        /// (snake_case stays as written).
        private static func closing(_ c: [Character], from i: Int, _ ch: Character, _ width: Int) -> Int? {
            let start = i + width
            guard start < c.count, !c[start].isWhitespace else { return nil }
            if ch == "_", i > 0, c[i - 1].isLetter || c[i - 1].isNumber { return nil }
            var j = start + 1
            while j + width <= c.count {
                if c[j..<(j + width)].allSatisfy({ $0 == ch }), !c[j - 1].isWhitespace {
                    let after = j + width
                    let longer = after < c.count && c[after] == ch
                    let boundary = ch != "_" || after == c.count || !(c[after].isLetter || c[after].isNumber)
                    if !longer || width == 2, boundary, !(width == 1 && j + 1 < c.count && c[j + 1] == ch) { return j }
                }
                j += 1
            }
            return nil
        }

        private static func linkAt(_ c: [Character], _ i: Int) -> ([Character], String, Int)? {
            var depth = 0
            var j = i
            while j < c.count {
                if c[j] == "[" { depth += 1 } else if c[j] == "]" { depth -= 1; if depth == 0 { break } }
                j += 1
            }
            guard j + 1 < c.count, c[j + 1] == "(" else { return nil }
            var k = j + 2, parens = 1
            while k < c.count {
                if c[k] == "(" { parens += 1 } else if c[k] == ")" { parens -= 1; if parens == 0 { break } }
                k += 1
            }
            guard k < c.count else { return nil }
            let url = String(c[(j + 2)..<k]).trimmingCharacters(in: .whitespaces)
            return (Array(c[(i + 1)..<j]), url, k + 1)
        }

        private static func safe(_ url: String) -> String? {
            guard let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
            return url
        }
    }
}
