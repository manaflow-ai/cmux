/// A stable identifier for the host on which a repository and its worktrees live.
public struct WorktreeHostID: RawRepresentable, Hashable, Codable, Sendable {
    /// The identifier used by ``LocalWorktreeExecutionHost``.
    public static let local = WorktreeHostID(rawValue: "local")

    /// The persisted or transported host identifier.
    public let rawValue: String

    /// Creates a host identifier.
    /// - Parameter rawValue: A value that is stable across host reconnections.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
