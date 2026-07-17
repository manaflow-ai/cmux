/// A request to reveal additional context around one hunk.
public struct DiffContextExpansionRequest: Sendable, Equatable {
    /// The repository-relative file path.
    public let path: String
    /// The hunk's zero-based index in the rendered file.
    public let hunkIndex: Int
    /// Which portion of context should be expanded.
    public let direction: Direction

    /// The supported context-expansion directions.
    public enum Direction: Sendable, Equatable {
        /// Reveal context before the hunk.
        case up
        /// Reveal context after the hunk.
        case down
        /// Reveal all available context around the hunk.
        case all
    }

    /// Creates a context-expansion request.
    /// - Parameters:
    ///   - path: Repository-relative file path.
    ///   - hunkIndex: Zero-based hunk index.
    ///   - direction: Portion of context to reveal.
    public init(path: String, hunkIndex: Int, direction: Direction) {
        self.path = path
        self.hunkIndex = hunkIndex
        self.direction = direction
    }
}
