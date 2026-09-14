import Foundation

/// A file provider whose filesystem lives outside this Mac.
protocol RemoteFileExplorerProvider: FileExplorerProvider {
    var displayTarget: String { get }
    func resolveHomePath() async throws -> String
    func downloadFile(path: String, to localURL: URL) async throws
}
