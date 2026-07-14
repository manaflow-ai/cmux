import Foundation

/// One file whose worktree content differs from `HEAD`.
public struct WorkspaceGitStatusFile: Equatable, Sendable {
    /// The repository-relative current path.
    public let path: String
    /// The repository-relative source path for a rename or copy, otherwise `nil`.
    public let oldPath: String?
    /// The normalized status code: `M`, `A`, `D`, or `R`. Copies map to `A`.
    public let status: String
    /// The number of added lines, or zero for binary files.
    public let additions: Int
    /// The number of deleted lines, or zero for binary files.
    public let deletions: Int
    /// Whether Git classified the file content as binary.
    public let binary: Bool
    /// Whether the path is untracked rather than present in the index or `HEAD`.
    public let untracked: Bool

    /// Creates a normalized workspace Git status entry.
    /// - Parameters:
    ///   - path: The repository-relative current path.
    ///   - oldPath: The repository-relative source path for a rename or copy.
    ///   - status: The normalized status code.
    ///   - additions: The number of added lines.
    ///   - deletions: The number of deleted lines.
    ///   - binary: Whether Git classified the content as binary.
    ///   - untracked: Whether the path is untracked.
    public init(
        path: String,
        oldPath: String?,
        status: String,
        additions: Int,
        deletions: Int,
        binary: Bool,
        untracked: Bool
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.binary = binary
        self.untracked = untracked
    }
}
