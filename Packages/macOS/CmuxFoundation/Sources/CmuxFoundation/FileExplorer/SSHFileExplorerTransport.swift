public import Foundation

/// Executes file-explorer operations against a remote host over SSH.
///
/// The I/O seam beneath ``FileExplorerProvider`` for remote roots: resolves the
/// remote home, lists directories, and downloads a single file. All requirements
/// are `nonisolated` so the SSH provider can drive them off the main actor.
public protocol SSHFileExplorerTransport: AnyObject {
    /// Resolves the remote `$HOME` for the connection.
    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String
    /// Lists the children of `path` on the remote host.
    nonisolated func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry]
    /// Downloads the remote file at `path` to `localURL`.
    nonisolated func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws
}
