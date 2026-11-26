#if os(iOS)
import Foundation
import SwiftUI

/// Inline Markdown for Feed content that stays inside the row's SwiftUI
/// layout. Document-level content uses the shared artifact renderer instead.
struct AgentFeedMarkdownText: View {
    let markdown: String
    let font: Font
    let color: Color
    let lineLimit: Int?

    private static let renderedCache: NSCache<NSString, AgentFeedMarkdownCacheEntry> = {
        let cache = NSCache<NSString, AgentFeedMarkdownCacheEntry>()
        cache.countLimit = 512
        return cache
    }()

    init(markdown: String, font: Font, color: Color = .primary, lineLimit: Int? = nil) {
        self.markdown = markdown
        self.font = font
        self.color = color
        self.lineLimit = lineLimit
    }

    var body: some View {
        Text(renderedMarkdown)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
    }

    private var renderedMarkdown: AttributedString {
        if let cached = Self.renderedCache.object(forKey: markdown as NSString) {
            return cached.value
        }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let rendered = (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
        Self.renderedCache.setObject(AgentFeedMarkdownCacheEntry(rendered), forKey: markdown as NSString)
        return rendered
    }
}

private final class AgentFeedMarkdownCacheEntry: NSObject {
    let value: AttributedString

    init(_ value: AttributedString) {
        self.value = value
    }
}
#endif
