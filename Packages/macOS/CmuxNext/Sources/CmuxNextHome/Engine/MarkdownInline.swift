import Foundation

/// Inline Markdown: `**bold**`, `__bold__`, `*italic*`, `` `code` ``,
/// `[text](target)` and backslash escapes. An unclosed marker stays literal.
nonisolated enum MarkdownInline {
    struct Run: Equatable {
        var text: String
        var style: MarkdownFormatter.Style
        var link: String?
    }

    static func runs(_ source: Substring) -> [Run] {
        var runs: [Run] = []
        var plain = ""
        let chars = Array(source)
        var i = 0
        func flush() {
            if !plain.isEmpty { runs.append(Run(text: plain, style: [])) }
            plain = ""
        }
        /// Markers with no occurrence after some position: a later search starts
        /// further right and cannot succeed either, so scans stay linear overall.
        var absentFrom: [String: Int] = [:]
        /// Index of the next `marker` at or after `start`, if any.
        func find(_ marker: [Character], from start: Int) -> Int? {
            let key = String(marker)
            if let absent = absentFrom[key], start >= absent { return nil }
            var j = start
            outer: while j + marker.count <= chars.count {
                if chars[j] == "\\" { j += 2; continue }
                for (offset, character) in marker.enumerated() where chars[j + offset] != character {
                    j += 1
                    continue outer
                }
                return j
            }
            absentFrom[key] = min(absentFrom[key] ?? start, start)
            return nil
        }
        func styled(_ start: Int, _ end: Int, _ style: MarkdownFormatter.Style) {
            flush()
            for inner in Self.runs(Substring(String(chars[start..<end]))) {
                runs.append(Run(text: inner.text, style: inner.style.union(style), link: inner.link))
            }
        }
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "\\", let next, "\\`*_[]()#+-.!>".contains(next) {
                plain.append(next)
                i += 2
            } else if c == "`", let end = find(["`"], from: i + 1), end > i + 1 {
                flush()
                runs.append(Run(text: String(chars[(i + 1)..<end]), style: .code))
                i = end + 1
            } else if (c == "*" || c == "_"), next == c, let end = find([c, c], from: i + 2), end > i + 2 {
                styled(i + 2, end, .bold)
                i = end + 2
            } else if c == "*", let next, next != " ", next != "*", let end = find(["*"], from: i + 1), end > i + 1,
                      chars[end - 1] != " " {
                styled(i + 1, end, .italic)
                i = end + 1
            } else if c == "[", let close = find(["]", "("], from: i + 1), let end = find([")"], from: close + 2) {
                flush()
                let target = String(chars[(close + 2)..<end])
                let label = String(chars[(i + 1)..<close])
                runs.append(Run(text: label.isEmpty ? target : label, style: .underline, link: target))
                i = end + 1
            } else {
                plain.append(c)
                i += 1
            }
        }
        flush()
        return runs
    }
}
