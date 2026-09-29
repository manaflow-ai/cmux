import Foundation

/// One block of agent Markdown.
public enum MarkdownBlock: Sendable, Hashable {
    /// A paragraph; inline Markdown is kept for the renderer.
    case paragraph(String)
    /// A heading with level 1 to 6.
    case heading(level: Int, text: String)
    /// A list item with its marker (`•` or `3.`) and nesting depth.
    case listItem(marker: String, depth: Int, text: String)
    /// A block quote line.
    case quote(String)
    /// A fenced code block. `language` is the info string, if any.
    case code(language: String?, text: String)
    /// A thematic break.
    case rule
}

/// Splits agent Markdown into blocks.
///
/// Agents stream Markdown a few characters at a time, so the parser tolerates partial
/// input: an unterminated code fence becomes a code block that grows as text arrives.
/// Inline syntax (emphasis, code spans, links) stays in the block text for the renderer.
///
/// ```swift
/// let blocks = MarkdownBlockParser().parse("# Title\n\n- one\n- two")
/// ```
public struct MarkdownBlockParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Parses `text` into blocks.
    public func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: (language: String?, fence: String, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = code {
                if trimmed.hasPrefix(open.fence) {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code?.lines.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = (info.isEmpty ? nil : info, fence, [])
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if let item = Self.listItem(line) {
                flushParagraph()
                blocks.append(item)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        if let open = code {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let body = line.dropFirst(indent)
        let depth = indent / 2
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            return .listItem(marker: "•", depth: depth, text: String(body.dropFirst(2)))
        }
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let punctuation = afterDigits.first, punctuation == "." || punctuation == ")",
              afterDigits.dropFirst().first == " " else { return nil }
        return .listItem(marker: "\(digits).", depth: depth, text: String(afterDigits.dropFirst(2)))
    }
}
