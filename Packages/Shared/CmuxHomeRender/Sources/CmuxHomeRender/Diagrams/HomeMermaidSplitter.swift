/// Cuts a message's text into text and Mermaid diagram pieces.
///
/// A diagram is a closed fenced code block (CommonMark rules: at most three
/// spaces of indentation, three or more backticks or tildes, closed by a
/// fence of the same character at least as long) whose info string's first
/// word is `mermaid`, in any case. Everything else stays text as written:
/// other fenced blocks (and a `mermaid` fence inside one of them), indented
/// code, and a `mermaid` fence that is not closed yet (an agent's reply that
/// is still streaming in).
///
/// ```swift
/// let segments = HomeMermaidSplitter().segments(in: "Flow:\n```mermaid\ngraph TD\nA-->B\n```")
/// // [.text("Flow:\n"), .mermaid(source: "graph TD\nA-->B", fenced: "```mermaid\ngraph TD\nA-->B\n```")]
/// ```
public struct HomeMermaidSplitter: Sendable {
    /// A splitter with the CommonMark fence rules.
    public init() {}

    /// The pieces of `text` in order; their ``HomeTextSegment/original`` values
    /// join back to `text`. A text without a closed Mermaid fence is one
    /// `.text` piece (none when `text` is empty).
    public func segments(in text: String) -> [HomeTextSegment] {
        guard !text.isEmpty else { return [] }
        guard text.lowercased().contains("mermaid") else { return [.text(text)] }
        // Lines as unicode-scalar ranges: "\r\n" is one Character, so lines split on the "\n" scalar.
        let scalars = text.unicodeScalars
        var lines: [Range<String.Index>] = []
        var start = scalars.startIndex
        for (index, scalar) in zip(scalars.indices, scalars) where scalar == "\n" {
            lines.append(start..<index)
            start = scalars.index(after: index)
        }
        lines.append(start..<scalars.endIndex)
        func line(_ k: Int) -> String {
            guard let range = lines[checked: k] else { return "" }
            return String(scalars.slice(range.lowerBound, range.upperBound))
        }

        var blocks: [(open: Int, close: Int, indent: Int)] = []
        var i = 0
        while i < lines.count {
            guard let open = fence(line(i)) else { i += 1; continue }
            guard let close = ((i + 1)..<lines.count).first(where: { closes(line($0), open) }) else {
                break // unclosed: the rest of the text is that block's (CommonMark), so it stays text
            }
            if open.isMermaid { blocks.append((i, close, open.indent)) }
            i = close + 1
        }
        guard !blocks.isEmpty else { return [.text(text)] }

        var out: [HomeTextSegment] = []
        var cursor = scalars.startIndex
        for block in blocks {
            guard let from = lines[checked: block.open]?.lowerBound, let to = lines[checked: block.close]?.upperBound else { continue }
            if cursor < from { out.append(.text(String(scalars.slice(cursor, from)))) }
            let source = ((block.open + 1)..<block.close).map { dedent(line($0), block.indent) }.joined(separator: "\n")
            out.append(.mermaid(source: source, fenced: String(scalars.slice(from, to))))
            cursor = to
        }
        if cursor < scalars.endIndex { out.append(.text(String(scalars.slice(from: cursor)))) }
        return out
    }

    /// An opening fence: indentation, fence character and length, and whether its info word is `mermaid`.
    private struct Fence {
        var indent: Int
        var character: Character
        var length: Int
        var isMermaid: Bool
    }

    private func fence(_ line: String) -> Fence? {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let length = rest.prefix { $0 == character }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length)
        if character == "`", info.contains("`") { return nil }
        let word = info.drop { $0.isWhitespace }.prefix { !$0.isWhitespace && $0 != "{" }
        return Fence(indent: indent, character: character, length: length, isMermaid: word.lowercased() == "mermaid")
    }

    private func closes(_ line: String, _ open: Fence) -> Bool {
        let indent = line.prefix { $0 == " " }.count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let length = rest.prefix { $0 == open.character }.count
        return length >= open.length && rest.dropFirst(length).allSatisfy(\.isWhitespace)
    }

    /// `line` without up to `indent` leading spaces and without a trailing carriage return.
    private func dedent(_ line: String, _ indent: Int) -> String {
        var line = Substring(line)
        var removed = 0
        while removed < indent, line.first == " " { line = line.dropFirst(); removed += 1 }
        if line.last == "\r" { line = line.dropLast() }
        return String(line)
    }
}
