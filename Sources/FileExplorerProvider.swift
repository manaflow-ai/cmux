import CmuxFileTree
import Foundation

/// A filesystem the Files tree can show: this Mac, an SSH host or a Cloud VM.
///
/// Each provider is also the ``FileTreeProvider`` the off-main
/// ``FileTreeEngine`` lists through, so every transport shares one loading,
/// diffing and change pipeline.
protocol FileExplorerProvider: AnyObject, FileTreeProvider {
    var homePath: String { get }
    var isAvailable: Bool { get }
}

enum FileExplorerRootResolver {
    static func displayPath(for fullPath: String, homePath: String?) -> String {
        guard let home = homePath, !home.isEmpty else { return fullPath }
        let normalizedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let normalizedPath = fullPath.hasSuffix("/") ? String(fullPath.dropLast()) : fullPath
        if normalizedPath == normalizedHome {
            return "~"
        }
        let homePrefix = normalizedHome + "/"
        if normalizedPath.hasPrefix(homePrefix) {
            return "~/" + normalizedPath.dropFirst(homePrefix.count)
        }
        return fullPath
    }
}

struct SSHFileExplorerConnection: Equatable, Sendable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
}

protocol SSHFileExplorerTransport: AnyObject, Sendable {
    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String
    /// Lists several directories in one SSH round trip.
    nonisolated func listDirectories(
        paths: [String],
        connection: SSHFileExplorerConnection
    ) async throws -> [String: Result<FileTreeListing, any Error>]
    nonisolated func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws
}

enum FileExplorerWorkspaceRoot: Equatable {
    case none
    case local(workspaceId: UUID, path: String)
    case remoteSSH(
        workspaceId: UUID,
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        rootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?
    )
    case remoteCloud(
        workspaceId: UUID,
        vmID: String,
        displayTarget: String,
        rootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?,
        target: CloudFileExplorerTarget?
    )
}
