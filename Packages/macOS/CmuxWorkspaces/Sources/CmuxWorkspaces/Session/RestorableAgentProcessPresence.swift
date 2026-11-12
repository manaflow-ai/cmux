/// Tri-state evidence about whether a recorded process ID is still occupied.
public enum RestorableAgentProcessPresence: Equatable, Hashable, Sendable {
    /// The process ID currently exists.
    case present
    /// The process ID is confirmed absent.
    case absent
    /// The process table could not establish whether the ID exists.
    case unknown
}

