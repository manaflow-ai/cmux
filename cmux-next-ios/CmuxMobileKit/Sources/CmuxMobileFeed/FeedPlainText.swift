import Foundation

/// Feed rows whose text needs no web view (full verify D10: 86 events, each
/// with a pooled WKWebView measured in JavaScript, hitched while scrolling).
/// Short text with at most inline markdown (bold, italics, code spans, links)
/// draws as native text; anything with blocks (code fences, lists, quotes,
/// headings, tables, HTML) keeps the web renderer.
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

/// `FeedPlainText`'s answer per body, kept so a row built again (scrolled back
/// in, or re-rendered by a live change) does not re-scan and re-parse its
/// markdown on the main thread. Bounded; emptied when it fills.
@MainActor
final class FeedInlineTextCache {
    static let shared = FeedInlineTextCache()
    /// nil value: the body needs the web renderer.
    private var entries: [String: AttributedString?] = [:]
    private let limit: Int
    private(set) var misses = 0

    init(limit: Int = 1024) {
        self.limit = limit
    }

    /// A web body's text for its fling placeholder: lines without fences,
    /// table rules, heading, quote and list marks, or emphasis characters.
    private var placeholders: [String: String] = [:]

    func placeholderText(_ markdown: String) -> String {
        if let hit = placeholders[markdown] { return hit }
        var lines: [String] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            if line.hasPrefix("|"), line.allSatisfy({ "|-: ".contains($0) }) { continue }
            while let first = line.first, "#>".contains(first) { line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { line = "• " + line.dropFirst(2) }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            lines.append(line)
        }
        let text = lines.joined(separator: "\n")
        if placeholders.count >= limit { placeholders = [:] }
        placeholders[markdown] = text
        return text
    }

    /// The body as native text, or nil when it needs the web renderer.
    func inlineText(_ markdown: String) -> AttributedString? {
        if let hit = entries[markdown] { return hit }
        misses += 1
        let plain = FeedPlainText(markdown)
        let value = plain.isInline ? plain.attributed : nil
        if entries.count >= limit { entries = [:] }
        entries[markdown] = .some(value)
        return value
    }
}
