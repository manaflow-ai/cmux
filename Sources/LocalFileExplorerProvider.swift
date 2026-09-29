import CmuxFileTree
import Foundation

/// This Mac's filesystem: `getattrlistbulk` listing plus FSEvents changes.
final class LocalFileExplorerProvider: FileExplorerProvider, Sendable {
    private let tree: LocalFileTreeProvider

    init(tree: LocalFileTreeProvider = LocalFileTreeProvider()) {
        self.tree = tree
    }

    var homePath: String { NSHomeDirectory() }
    var isAvailable: Bool { true }

    func listDirectory(at path: String) async throws -> FileTreeListing {
        try await tree.listDirectory(at: path)
    }

    func changes(under rootPath: String) -> AsyncStream<FileTreeChangeBatch>? {
        tree.changes(under: rootPath)
    }
}
