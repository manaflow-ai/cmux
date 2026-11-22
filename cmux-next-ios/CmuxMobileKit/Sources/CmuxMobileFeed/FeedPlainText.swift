import CmuxMobileMarkdown
import Foundation

/// Feed rows whose text needs no web view (full verify D10: 86 events, each
/// with a pooled WKWebView measured in JavaScript, hitched while scrolling).
/// Short text with at most inline markdown (bold, italics, code spans, links)
/// draws as native text; anything with blocks (code fences, lists, quotes,
/// headings, tables, HTML) or math keeps the full markdown renderer.
public struct FeedPlainText: Sendable {
    /// At most this many characters and lines: always under the collapsed
    /// height (8 body lines), so no Show more is needed.
    static let maxCharacters = 280
    static let maxLines = 4

    public let markdown: String

    public init(_ markdown: String) {
        self.markdown = markdown
    }

    /// Whether native text draws this as the web view would.
    public var isInline: Bool {
        guard markdown.count <= Self.maxCharacters, !markdown.contains("```"), !markdown.contains("<") else { return false }
        // Use the transcript's parser so short math reaches the shared web
        // renderer too. Ordinary prices and escaped dollar signs stay native.
        if markdown.contains("$") || markdown.contains("\\") {
            guard !MarkdownDocument(parsing: markdown).needsWebRenderer else { return false }
        }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= Self.maxLines else { return false }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || trimmed.hasPrefix("|") || trimmed.hasPrefix("- ")
                || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || trimmed.hasPrefix("    ")
                || trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil {
                return false
            }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { return false }
            // Setext underlines and thematic breaks (`===`, `---`, `***`, `___`).
            if trimmed.count >= 3, Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1,
               let mark = trimmed.first, "=-*_".contains(mark) { return false }
        }
        return true
    }

    /// The inline markdown as attributed text; nil when it does not parse.
    public var attributed: AttributedString? {
        try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
}
