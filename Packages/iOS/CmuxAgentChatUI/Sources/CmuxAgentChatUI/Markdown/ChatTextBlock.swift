import Foundation

/// One block-level element of agent prose. Block structure (headings,
/// lists, quotes) is laid out as distinct styled rows; inline markdown
/// (bold/italic/code/links) is rendered within each block's text.
///
/// Coding agents emit headings and lists in nearly every reply, so without
/// block layout the raw `##` / `- ` markers render literally.
public struct ChatTextBlock: Sendable, Equatable, Identifiable {
    /// The block's structural kind.
    public enum Kind: Sendable, Equatable {
        /// A heading; `level` is 1...6.
        case heading(level: Int)
        /// A paragraph of running text.
        case paragraph
        /// A bullet list item at `indent` depth (0-based).
        case bullet(indent: Int)
        /// An ordered list item showing `marker` (e.g. "1.") at `indent`.
        case ordered(marker: String, indent: Int)
        /// A block quote.
        case quote
        /// A horizontal rule / section divider (`---`, `***`, `___`).
        case rule
    }

    /// Position within the segment, for stable identity.
    public let index: Int

    /// The block's structural kind.
    public let kind: Kind

    /// The block's inline-markdown text (markers stripped).
    public let text: String

    /// Stable identity within the segment.
    public var id: Int { index }

    /// Creates a text block.
    public init(index: Int, kind: Kind, text: String) {
        self.index = index
        self.kind = kind
        self.text = text
    }
}

/// Parses a prose text run (already split out from code fences) into
/// block-level elements. Pure and synchronous for testability.
public struct ChatTextBlockParser: Sendable {
    /// Creates a parser.
    public init() {}

    /// Splits `text` into blocks.
    ///
    /// Consecutive plain lines coalesce into one paragraph (preserving
    /// their soft breaks); a blank line ends the current paragraph. List
    /// items and headings each form their own block so they can be laid
    /// out with hanging indents and heading type styles.
    ///
    /// - Parameter text: A markdown text run.
    /// - Returns: Blocks in display order; empty only for blank input.
    public func blocks(from text: String) -> [ChatTextBlock] {
        var blocks: [ChatTextBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = []
            guard !joined.isEmpty else { return }
            blocks.append(ChatTextBlock(index: blocks.count, kind: .paragraph, text: joined))
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }
            if let block = Self.structuralBlock(from: line, index: 0) {
                flushParagraph()
                blocks.append(ChatTextBlock(index: blocks.count, kind: block.kind, text: block.text))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    /// Recognizes a single structural line (heading / list / quote),
    /// returning its kind and stripped text, or `nil` for plain prose.
    private static func structuralBlock(from line: String, index: Int) -> ChatTextBlock? {
        let indentWidth = line.prefix { $0 == " " }.count
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = indentWidth / 2

        // ATX heading: 1-6 '#' then a space.
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes >= 1, hashes <= 6 {
                let rest = trimmed.dropFirst(hashes)
                if rest.hasPrefix(" ") {
                    return ChatTextBlock(
                        index: index,
                        kind: .heading(level: hashes),
                        text: rest.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }

        // Horizontal rule: 3+ of a single marker char (-, *, _), allowing
        // spaces between them and nothing else (`---`, `***`, `- - -`).
        // Checked before bullets so `* * *` / `- - -` aren't read as a
        // bullet whose text is "* *".
        let ruleChars = trimmed.filter { !$0.isWhitespace }
        if ruleChars.count >= 3,
           let marker = ruleChars.first, "-*_".contains(marker),
           ruleChars.allSatisfy({ $0 == marker }) {
            return ChatTextBlock(index: index, kind: .rule, text: "")
        }

        // Bullet: -, *, or + then a space.
        if let first = trimmed.first, "-*+".contains(first) {
            let rest = trimmed.dropFirst()
            if rest.hasPrefix(" ") {
                return ChatTextBlock(
                    index: index,
                    kind: .bullet(indent: indent),
                    text: rest.trimmingCharacters(in: .whitespaces)
                )
            }
        }

        // Ordered: digits then '.' or ')' then a space.
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = trimmed.dropFirst(digits.count)
            if let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" {
                let rest = afterDigits.dropFirst()
                if rest.hasPrefix(" ") {
                    return ChatTextBlock(
                        index: index,
                        kind: .ordered(marker: "\(digits)\(delimiter)", indent: indent),
                        text: rest.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
        }

        // Block quote.
        if trimmed.hasPrefix(">") {
            return ChatTextBlock(
                index: index,
                kind: .quote,
                text: trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            )
        }

        return nil
    }
}
