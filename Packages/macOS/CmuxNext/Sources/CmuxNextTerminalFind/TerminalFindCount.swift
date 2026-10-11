/// What the find bar's count label shows.
public enum TerminalFindCount: Sendable, Equatable {
    /// Nothing: no query, or the search has not reported yet.
    case empty
    /// The query matches nothing.
    case noMatches
    /// The selected match's 1-based position among `total` matches.
    case position(Int, of: Int)

    /// The label for a query and Ghostty's 0-based `selected` index among
    /// `total` matches (either nil until the search reports it).
    public init(query: String, total: Int?, selected: Int?) {
        guard !query.isEmpty, let total else {
            self = .empty
            return
        }
        if total == 0 {
            self = .noMatches
        } else if let selected, selected < total {
            self = .position(selected + 1, of: total)
        } else {
            self = .empty
        }
    }
}
