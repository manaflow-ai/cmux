import Foundation

/// A history entry with its match fields precomputed (lowercased URL, host,
/// path+query, title) so omnibar scoring avoids re-parsing the URL and
/// re-lowercasing on every keystroke.
///
/// The owning store builds these lazily for all entries and caches them,
/// rebuilding only when the entry list changes; steady-state typing then pays
/// only the cheap substring scoring in
/// ``BrowserHistorySuggestionEngine/score(candidate:query:queryTokens:now:)``.
public struct BrowserHistorySuggestionCandidate: Sendable {
    /// The source history entry this candidate scores.
    public let entry: BrowserHistoryEntry
    /// Full lowercased URL string.
    public let urlLower: String
    /// Lowercased URL with any `http://`/`https://` prefix removed.
    public let urlSansSchemeLower: String
    /// Lowercased host component.
    public let hostLower: String
    /// Lowercased path joined with the query (`path?query`), percent-encoded.
    public let pathAndQueryLower: String
    /// Lowercased, whitespace-trimmed page title.
    public let titleLower: String

    /// Creates a candidate from already-computed match fields.
    public init(
        entry: BrowserHistoryEntry,
        urlLower: String,
        urlSansSchemeLower: String,
        hostLower: String,
        pathAndQueryLower: String,
        titleLower: String
    ) {
        self.entry = entry
        self.urlLower = urlLower
        self.urlSansSchemeLower = urlSansSchemeLower
        self.hostLower = hostLower
        self.pathAndQueryLower = pathAndQueryLower
        self.titleLower = titleLower
    }
}
