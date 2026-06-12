import Foundation
import SwiftUI

/// Bounded main-actor cache of parsed markdown, keyed by message identity.
///
/// Markdown parsing is too expensive to repeat every time a lazy row
/// re-materializes during scrolling. This type is deliberately **not**
/// `@Observable`: it never changes observably, so passing it through the
/// environment cannot invalidate rows (snapshot-boundary rule). Streaming
/// updates re-render only the changing message because the cache key
/// includes the text's hash.
@MainActor
public final class ChatMarkdownRenderer {
    private var cache: [String: AttributedString] = [:]
    private var insertionOrder: [String] = []
    private let capacity: Int

    /// Creates a renderer.
    ///
    /// - Parameter capacity: Maximum cached entries before the oldest are
    ///   evicted; sized to comfortably cover the visible window.
    public init(capacity: Int = 800) {
        self.capacity = capacity
    }

    /// Parses `markdown` (or returns the cached parse) as inline-styled
    /// attributed text that preserves whitespace and line breaks.
    ///
    /// - Parameters:
    ///   - messageID: Stable identity of the owning message.
    ///   - markdown: The markdown source text.
    /// - Returns: Attributed text; falls back to the plain text when the
    ///   source fails to parse as markdown.
    public func render(messageID: String, markdown: String) -> AttributedString {
        let key = "\(messageID)-\(markdown.hashValue)"
        if let cached = cache[key] {
            return cached
        }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let rendered = (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
        if cache.count >= capacity, let oldest = insertionOrder.first {
            cache[oldest] = nil
            insertionOrder.removeFirst()
        }
        cache[key] = rendered
        insertionOrder.append(key)
        return rendered
    }
}

extension EnvironmentValues {
    /// The markdown renderer for transcript rows, injected by the screen
    /// that owns the conversation. Rows fall back to uncached parsing when
    /// absent (previews).
    @Entry public var chatMarkdownRenderer: ChatMarkdownRenderer? = nil
}
