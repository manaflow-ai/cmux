/// Evidence about whether an observed process is the recorded restorable agent generation.
public enum RestorableAgentProcessMatch: Equatable, Hashable, Sendable {
    /// The process is the same recorded agent generation.
    case matches
    /// The process is absent, reused, or belongs to another agent generation.
    case mismatches
    /// The process may still exist, but it cannot be identified conclusively.
    case unknown
}
