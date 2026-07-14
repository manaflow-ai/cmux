import Foundation

/// One requested repository path and its optional rename source path.
public struct WorkspaceGitDiffPath: Equatable, Sendable {
    /// The repository-relative current path.
    public let path: String
    /// The repository-relative prior path for a rename, otherwise `nil`.
    public let oldPath: String?

    /// Creates a requested diff path.
    /// - Parameters:
    ///   - path: The repository-relative current path.
    ///   - oldPath: The repository-relative prior path for a rename.
    public init(path: String, oldPath: String? = nil) {
        self.path = path
        self.oldPath = oldPath
    }
}
