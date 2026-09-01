/// The launch provenance retained by a structured agent restore.
public enum AgentRestoreRoute: String, Sendable, Equatable {
    /// The agent launches without a managed Subrouter route.
    case direct

    /// Subrouter chooses an account from its available pool.
    case pooled

    /// The restore retains an explicit account or profile selection.
    case pinned
}
