/// What the find bar's count label shows.
public enum TerminalFindCount: Sendable, Equatable {
    /// Nothing: no query, or the search has not reported yet.
    case empty
    /// The query matches nothing.
    case noMatches
    /// The selected match's 1-based position among `total` matches.
    case position(Int, of: Int)
    /// The same while the search still reads older rows: `total` only grows ("3 of 120+").
    case partial(Int, of: Int)
    /// The regex does not compile; the reason is the daemon's.
    case invalidPattern(String)

    /// The label for a query and Ghostty's 0-based `selected` index among
    /// `total` matches (either nil until the search reports it).
    ///
    /// - Parameters:
    ///   - searching: Older rows are still being read, so `total` may grow.
    ///   - invalidPattern: The daemon's reason the regex did not compile.
    public init(query: String, total: Int?, selected: Int?, searching: Bool = false, invalidPattern: String? = nil) {
        guard !query.isEmpty else {
            self = .empty
            return
        }
        if let invalidPattern {
            self = .invalidPattern(invalidPattern)
            return
        }
        guard let total else {
            self = .empty
            return
        }
        if total == 0 {
            self = searching ? .empty : .noMatches
        } else if let selected, selected < total {
            self = searching ? .partial(selected + 1, of: total) : .position(selected + 1, of: total)
        } else if searching {
            self = .partial(0, of: total)
        } else {
            self = .empty
        }
    }
}
