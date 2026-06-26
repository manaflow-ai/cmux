import Foundation

/// The file-explorer root requested for a workspace.
///
/// Drives ``FileExplorerStore`` to show no files, a local directory, or a remote
/// SSH directory. Equatable so the store can detect when a workspace's requested
/// root is unchanged and avoid redundant reloads.
public enum FileExplorerWorkspaceRoot: Equatable {
    /// No file explorer (no workspace or an unsupported workspace).
    case none
    /// A local directory rooted at `path` for the given workspace.
    case local(workspaceId: UUID, path: String)
    /// A remote directory served over SSH for the given workspace.
    case remoteSSH(
        workspaceId: UUID,
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        rootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?
    )
}
