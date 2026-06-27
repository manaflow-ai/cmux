/// Immutable snapshot of a file-search session: the query, the matches found so
/// far, the lifecycle status, and whether a search is still running.
///
/// Published to observers as the search progresses; `.empty` is the
/// pre-search resting value.
public struct FileSearchSnapshot: Equatable, Sendable {
    /// Lifecycle state of a file-search session.
    public enum Status: Equatable, Sendable {
        /// No search has run (resting state).
        case idle
        /// Search is unsupported in the current context (e.g. non-local root).
        case unsupported
        /// A search is in progress.
        case searching
        /// The search completed with no matches.
        case noMatches
        /// The search completed with matches.
        case matches
        /// The search hit its result cap; the associated value is the cap.
        case limited(Int)
        /// The search failed; the associated value is the error message.
        case failed(String)
    }

    /// The query string this snapshot reflects.
    public var query: String
    /// Matches found so far.
    public var results: [FileSearchResult]
    /// Lifecycle status of the search.
    public var status: Status
    /// Whether a search is still running.
    public var isSearching: Bool

    /// - Parameters:
    ///   - query: the query string this snapshot reflects.
    ///   - results: matches found so far.
    ///   - status: lifecycle status of the search.
    ///   - isSearching: whether a search is still running.
    public init(
        query: String,
        results: [FileSearchResult],
        status: Status,
        isSearching: Bool
    ) {
        self.query = query
        self.results = results
        self.status = status
        self.isSearching = isSearching
    }

    /// The pre-search resting snapshot: empty query, no results, idle, not searching.
    public static let empty = FileSearchSnapshot(query: "", results: [], status: .idle, isSearching: false)
}
