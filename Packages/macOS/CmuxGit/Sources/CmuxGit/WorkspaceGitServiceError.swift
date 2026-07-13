import Foundation

/// Failures produced while reading a workspace repository through system Git.
public enum WorkspaceGitServiceError: Error, Equatable, Sendable {
    /// The workspace directory is not inside a Git repository.
    case notRepository
    /// A Git subprocess failed or returned malformed output.
    case commandFailed(operation: String)
    /// A requested diff path is not a safe repository-relative path.
    case invalidPath(String)
}
