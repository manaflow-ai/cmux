import Foundation

/// The streaming tail of an agent message, as ChatGPT and Claude show it: an emphasis or
/// code marker whose closing half has not arrived yet is hidden, so `*Make the` never
/// flashes a literal `*`. Once the marker closes, the text renders styled.
public struct MarkdownStreamTail: Sendable {
    public let source: String

    public init(_ source: String) {
        self.source = source
    }

    /// The source with unmatched inline markers removed from its last block. Text inside an
    /// unclosed fenced code block or display math is left as is.
    public var displayed: String {
        let lines = source.components(separatedBy: "\n")
        let fences = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
        if fences % 2 == 1 { return source }
        let blockStart = source.range(of: "\n\n", options: .backwards)?.upperBound ?? source.startIndex
        let tail = String(source[blockStart...])
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$$") || trimmed.hasPrefix("|") || trimmed.hasPrefix("```") { return source }
        return String(source[..<blockStart]) + Self.closingUnmatched(tail)
    }

    /// Removes the last unmatched opener of `` ` ``, `**`, `~~`, `*` and `_` (in that order).
    static func closingUnmatched(_ text: String) -> String {
        var chars = Array(text)
        // Inline code first: inside a code span nothing else is a marker.
        let ticks = chars.indices.filter { chars[$0] == "`" }
        if ticks.count % 2 == 1, let last = ticks.last {
            chars.remove(at: last)
        }
        let code = codeSpans(chars)
        func outside(_ i: Int) -> Bool { !code.contains { $0.contains(i) } }

        for pair in ["**", "~~"] {
            let p = Array(pair)
            var hits: [Int] = []
            var i = 0
            while i + 1 < chars.count {
                if chars[i] == p[0], chars[i + 1] == p[1], outside(i) {
                    hits.append(i)
                    i += 2
                } else {
                    i += 1
                }
            }
            if hits.count % 2 == 1, let last = hits.last {
                chars.removeSubrange(last..<last + 2)
            }
        }
        let codeAfter = codeSpans(chars)
        func outsideAfter(_ i: Int) -> Bool { !codeAfter.contains { $0.contains(i) } }
        for marker in ["*", "_"] as [Character] {
            var hits: [Int] = []
            for i in chars.indices where chars[i] == marker && outsideAfter(i) {
                let before: Character? = i > 0 ? chars[i - 1] : nil
                let after: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                // Part of a `**` pair (already balanced above).
                if before == marker || after == marker { continue }
                // A list bullet (`* item`) or arithmetic (`a * b`).
                if marker == "*", after == " " || after == nil, before == nil || before == " " || before == "\n" { continue }
                // Intra-word underscores (`snake_case`) are not emphasis.
                if marker == "_", let b = before, let a = after, b.isLetter || b.isNumber, a.isLetter || a.isNumber { continue }
                hits.append(i)
            }
            if hits.count % 2 == 1, let last = hits.last {
                chars.remove(at: last)
            }
        }
        return String(chars)
    }

    private static func codeSpans(_ chars: [Character]) -> [ClosedRange<Int>] {
        let ticks = chars.indices.filter { chars[$0] == "`" }
        return stride(from: 0, to: ticks.count - 1, by: 2).map { ticks[$0]...ticks[$0 + 1] }
    }
}
