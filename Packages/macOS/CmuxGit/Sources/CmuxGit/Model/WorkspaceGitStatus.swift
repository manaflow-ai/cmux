import Foundation

/// A point-in-time summary of all worktree changes relative to `HEAD`.
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

    /// Creates a workspace Git status summary.
    /// - Parameters:
    ///   - repoRoot: The absolute repository root.
    ///   - baseline: The baseline identifier.
    ///   - files: The normalized changed files.
    ///   - totalAdditions: The total number of added lines.
    ///   - totalDeletions: The total number of deleted lines.
    public init(
        repoRoot: String,
        baseline: String,
        files: [WorkspaceGitStatusFile],
        totalAdditions: Int,
        totalDeletions: Int
    ) {
        self.repoRoot = repoRoot
        self.baseline = baseline
        self.files = files
        self.totalAdditions = totalAdditions
        self.totalDeletions = totalDeletions
    }
}
