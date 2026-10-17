public import Foundation

/// A "Search … for" row that searches the selection with cmux's configured search engine, in
/// place of Chromium's own row (which searches with Chromium's default engine).
public struct BrowserContextMenuWebSearch: Hashable, Sendable {
    /// The search engine's display name.
    public var engineName: String
    /// The selected text being searched.
    public var query: String
    /// The search results page to open.
    public var url: URL

    /// Creates a search row.
    /// - Parameters:
    ///   - engineName: The search engine's display name.
    ///   - query: The selected text.
    ///   - url: The search results page.
    public init(engineName: String, query: String, url: URL) {
        self.engineName = engineName
        self.query = query
        self.url = url
    }

    /// The query on one line, at most 50 characters, as Chrome quotes it in the row title.
    public var snippet: String {
        let limit = 50
        let line = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "\u{2026}" : line
    }
}
