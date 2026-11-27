import Foundation

/// A file provider whose filesystem lives outside this Mac.
protocol RemoteFileExplorerProvider: FileExplorerProvider, Sendable {
    nonisolated var remoteIdentity: String { get }
    nonisolated var displayTarget: String { get }
    nonisolated func resolveHomePath() async throws -> String
    nonisolated func downloadFile(path: String, to localURL: URL) async throws
}
