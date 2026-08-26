/// Whether a Hermes session identifier is backed by a resumable `state.db` row.
public enum HermesAgentSessionExistence: Equatable, Sendable {
    /// Hermes has a resumable CLI or TUI session with this identifier.
    case exists
    /// Hermes's readable database does not contain this identifier.
    case missing
    /// The database could not be snapshotted or queried safely.
    case unavailable
}
