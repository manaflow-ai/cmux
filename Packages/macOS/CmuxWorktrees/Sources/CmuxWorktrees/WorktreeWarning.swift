/// A non-fatal diagnostic produced while creating a worktree.
public struct WorktreeWarning: Equatable, Codable, Sendable {
    /// A stable machine-readable warning category.
    public enum Kind: String, Codable, Sendable {
        /// `push.autoSetupRemote` could not be set.
        case pushAutoSetupRemote
        /// The worktree's branch lineage could not be recorded.
        case branchBase
    }

    /// The machine-readable warning category.
    public let kind: Kind

    /// A human-readable explanation suitable for logs or CLI stderr.
    public let message: String

    /// Creates a non-fatal diagnostic.
    /// - Parameters:
    ///   - kind: The warning category.
    ///   - message: A human-readable explanation.
    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}
