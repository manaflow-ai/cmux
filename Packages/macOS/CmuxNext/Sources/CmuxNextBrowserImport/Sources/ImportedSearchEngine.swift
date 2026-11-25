public import Foundation

/// A source profile's default search engine: its name, keyword and address
/// templates (`{searchTerms}` marks the typed text), as the daemon's
/// `browser_import.read` reads it (``BrowserDataReader/searchEngine(_:)``).
public struct ImportedSearchEngine: Sendable, Codable, Equatable {
    public var name: String
    public var keyword: String?
    public var search: String
    public var suggest: String?

    public init(name: String, keyword: String? = nil, search: String, suggest: String? = nil) {
        self.name = name
        self.keyword = keyword
        self.search = search
        self.suggest = suggest
    }
}
