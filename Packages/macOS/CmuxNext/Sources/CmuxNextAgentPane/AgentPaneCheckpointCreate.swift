import Foundation

/// What `git.checkpoint.create` captures beyond the tracked files, as the
/// page's review sends it. A nil field is left out, and the session host
/// applies its default.
public nonisolated struct AgentPaneCheckpointCreate: Equatable, Sendable {
    /// The untracked files to store.
    public nonisolated enum Untracked: Equatable, Sendable {
        /// These paths, relative to the repository root.
        case paths([String])
        /// Every candidate the session host marks eligible at capture time.
        case eligible
    }

    /// Why the checkpoint is made.
    public nonisolated enum Reason: String, Equatable, Sendable {
        case manual
        case handoff
    }

    /// Caps on the capture below the session host's advertised ones.
    public nonisolated struct Limits: Equatable, Sendable {
        public var maxBytes: Int?
        public var maxFiles: Int?

        public init(maxBytes: Int? = nil, maxFiles: Int? = nil) {
            self.maxBytes = maxBytes
            self.maxFiles = maxFiles
        }
    }

    /// Refuses the capture when the folder now names another repository.
    public var expectedRepositoryID: String?
    /// Refuses the capture when the folder now names another worktree.
    public var expectedWorktreeID: String?
    public var includeUntracked: Untracked?
    /// Files or folders left out of every tree, relative to the root.
    public var excludePaths: [String]?
    public var reason: Reason?
    public var limits: Limits?

    public init(
        expectedRepositoryID: String? = nil, expectedWorktreeID: String? = nil, includeUntracked: Untracked? = nil,
        excludePaths: [String]? = nil, reason: Reason? = nil, limits: Limits? = nil
    ) {
        self.expectedRepositoryID = expectedRepositoryID
        self.expectedWorktreeID = expectedWorktreeID
        self.includeUntracked = includeUntracked
        self.excludePaths = excludePaths
        self.reason = reason
        self.limits = limits
    }
}
