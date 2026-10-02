/// What the find bar's count label shows.
public enum TerminalFindCount: Sendable, Equatable {
    case empty
    case noMatches
    case position(Int, of: Int)

    /// Placeholder for the failing tests.
    public init(query: String, total: Int?, selected: Int?) {
        self = .empty
    }
}
