import Foundation

/// Turns an agent's Markdown into what voice mode reads aloud: the agent's
/// own words, near verbatim, without what is useless to the ear. Code
/// blocks, diffs, tables, images, long inline code and raw URLs are left
/// out; links keep their text; Markdown markers go. A message that is only
/// code says nothing (nil), so the voice stays quiet rather than reading it.
public struct AgentVoiceSpeech: Sendable, Equatable {
    /// Longest text read for one message; longer text stops at a sentence end.
    public var maxCharacters: Int
    /// Inline code longer than this is dropped (a path or a name is kept).
    public var maxInlineCode: Int

    public init(maxCharacters: Int = 1200, maxInlineCode: Int = 40) {
        self.maxCharacters = maxCharacters
        self.maxInlineCode = maxInlineCode
    }

    /// What to say for `markdown`, or nil when nothing in it is worth saying.
    public func speakable(_ markdown: String) -> String? {
        var kept: [String] = []
        var fence: Substring?
        var diffRun: [String] = []

        func flushDiffRun() {
            // One `-`/`+` line is a list item; two or more in a row are a diff.
            if diffRun.count == 1 { kept.append(diffRun[0]) }
            diffRun.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if line.hasPrefix(open) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushDiffRun()
                fence = line.prefix(3)
                continue
            }
            // A horizontal rule (`---`, `***`) is layout, not a diff line.
            if !line.isEmpty, line.allSatisfy({ "-*_= ".contains($0) }) {
                flushDiffRun()
                continue
            }
            if Self.isDiffLine(line) {
                diffRun.append(line)
                continue
            }
            flushDiffRun()
            // Tables, rules and HTML are layout, not speech.
            if line.hasPrefix("|") || line.hasPrefix("<") {
                continue
            }
            // Indented code (a tab or four spaces) that is not a nested list item.
            if rawLine.hasPrefix("\t") || rawLine.hasPrefix("    "), !Self.isListItem(line) {
                continue
            }
            kept.append(line)
        }
        flushDiffRun()

        // Wrapped lines join into their paragraph; a blank line, a heading or
        // a list item starts a new block.
        var blocks: [String] = []
        var current = ""
        for line in kept {
            let startsBlock = line.isEmpty || line.hasPrefix("#") || line.hasPrefix(">") || Self.isListItem(line)
                || current.hasPrefix("#") // a heading is a block of its own
            if startsBlock, !current.isEmpty {
                blocks.append(current)
                current = ""
            }
            guard !line.isEmpty else { continue }
            current = current.isEmpty ? line : current + " " + line
        }
        if !current.isEmpty { blocks.append(current) }

        let sentences = blocks
            .map(spokenLine)
            .filter { !$0.isEmpty }
            .map { line -> String in
                // A line read as its own sentence: a list item, a heading.
                guard let last = line.last, !".!?:;,…".contains(last) else { return line }
                return line + "."
            }
        let text = sentences.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: \.isLetter) else { return nil }
        return truncated(text)
    }

    /// One line without Markdown: markers, links, images, inline code.
    func spokenLine(_ line: String) -> String {
        var text = line
        // Headings, quotes, list markers and task boxes.
        text = text.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*)+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
        // Images say nothing; links say their text.
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Inline code: short names are read, long snippets are not.
        text = replaceInlineCode(in: text)
        // Raw URLs are unreadable aloud.
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        // Emphasis markers.
        text = text.replacingOccurrences(of: #"(\*\*|__|\*|~~)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<![A-Za-z0-9])_([^_]+)_(?![A-Za-z0-9])"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func replaceInlineCode(in text: String) -> String {
        guard text.contains("`") else { return text }
        var out = ""
        var code: String?
        for character in text {
            if character == "`" {
                if let span = code {
                    if span.count <= maxInlineCode, !span.contains("\n") { out += span }
                    code = nil
                } else {
                    code = ""
                }
            } else if code != nil {
                code?.append(character)
            } else {
                out.append(character)
            }
        }
        if let open = code { out += open } // an unclosed tick is just a tick
        return out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    private func truncated(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        let head = text.prefix(maxCharacters)
        if let end = head.lastIndex(where: { ".!?".contains($0) }), head.distance(from: head.startIndex, to: end) > maxCharacters / 3 {
            return String(head[...end])
        }
        return String(head) + "…"
    }

    static func isDiffLine(_ line: String) -> Bool {
        line.hasPrefix("@@") || line.hasPrefix("diff --git") || line.hasPrefix("+++ ") || line.hasPrefix("--- ")
            || line.hasPrefix("index ") && line.contains("..")
            || (line.hasPrefix("+") || line.hasPrefix("-")) && !line.hasPrefix("- ") && !line.hasPrefix("+ ") && line.count > 1
            || line == "+" || line == "-"
    }

    static func isListItem(_ line: String) -> Bool {
        line.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) != nil
    }
}
