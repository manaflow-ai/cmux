/// What a `git.diff` compares (the session host's `GitDiffScope`).
public enum GitDiffScope: String, Hashable, Sendable, Codable, CaseIterable {
    /// The working tree against HEAD, with untracked files.
    case uncommitted
    /// The working tree against the index, with untracked files.
    case unstaged
    /// The index against HEAD.
    case staged
    /// HEAD against its first parent.
    case committed
    /// The working tree against the merge base with the base branch.
    case branch
}
