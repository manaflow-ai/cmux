import Foundation

/// A point-in-time summary of all worktree changes relative to `HEAD`, or the
/// empty tree when the repository has no commits.
public struct WorkspaceGitStatus: Equatable, Sendable {
    /// The absolute root of the enclosing repository.
    public let repoRoot: String
    /// The baseline identifier, currently always `worktree`.
    public let baseline: String
    /// Changed files in Git porcelain order.
    public let files: [WorkspaceGitStatusFile]
    /// Added lines summed across non-binary files.
    public let totalAdditions: Int
    /// Deleted lines summed across non-binary files.
    public let totalDeletions: Int
    /// Whether more untracked paths existed than the service processing cap.
    public let truncatedUntracked: Bool

    /// Creates a workspace Git status summary.
    /// - Parameters:
    ///   - repoRoot: The absolute repository root.
    ///   - baseline: The baseline identifier.
    ///   - files: The normalized changed files.
    ///   - totalAdditions: The total number of added lines.
    ///   - totalDeletions: The total number of deleted lines.
    ///   - truncatedUntracked: Whether untracked paths were capped.
    public init(
        repoRoot: String,
        baseline: String,
        files: [WorkspaceGitStatusFile],
        totalAdditions: Int,
        totalDeletions: Int,
        truncatedUntracked: Bool
    ) {
        self.repoRoot = repoRoot
        self.baseline = baseline
        self.files = files
        self.totalAdditions = totalAdditions
        self.totalDeletions = totalDeletions
        self.truncatedUntracked = truncatedUntracked
    }
}
