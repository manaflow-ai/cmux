/// The result of one paired-Mac restore attempt.
public struct RestoreOutcome: Sendable, Equatable {
    /// Whether the backup fetch succeeded, even if it returned no hosts.
    public let completed: Bool
    /// Number of backup records written into the local store.
    public let restored: Int
}
