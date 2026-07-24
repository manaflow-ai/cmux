/// The visual edge from which hidden context is revealed.
enum DiffExpansionDirection: Sendable, Equatable {
    /// Reveals lines upward from the hunk below a gap.
    case up
    /// Reveals lines downward from the hunk above a gap.
    case down
}
