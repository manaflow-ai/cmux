import AppKit
import CmuxFileTree

/// One row in the Files outline.
///
/// Nodes are reference objects with a stable identity per path: a refresh
/// reuses the same node for a surviving path, so `NSOutlineView` keeps its
/// selection, expansion and cell across incremental updates. `children` is
/// `nil` until the directory has been listed.
@MainActor
final class FileExplorerNode: NSObject {
    let path: String
    private(set) var entry: FileTreeEntry
    weak var parent: FileExplorerNode?
    /// Children in display order; `nil` while the directory is unlisted.
    var children: [FileExplorerNode]?
    /// Whether a listing for this directory is in flight.
    var isLoading = false
    /// The last listing error, shown on the row until a listing succeeds.
    var error: String?
    /// Entries the provider left out of this directory's listing.
    var omittedCount = 0
    /// A collapsed directory whose contents changed since it was listed. It
    /// re-lists on the next expansion instead of on every change event.
    var isStale = false
    var resourceContextID: UUID?

    var id: String { path }
    var name: String { entry.name }
    var isDirectory: Bool { entry.isDirectory }
    var isExpandable: Bool { entry.isDirectory }
    var isSymbolicLink: Bool {
        entry.kind == .symbolicLink || entry.kind == .symbolicLinkToDirectory
    }

    init(entry: FileTreeEntry, parent: FileExplorerNode?, resourceContextID: UUID?) {
        self.path = entry.path
        self.entry = entry
        self.parent = parent
        self.resourceContextID = resourceContextID
    }

    /// Creates a detached node; used by tests and drag fixtures.
    convenience init(name: String, path: String, isDirectory: Bool) {
        self.init(
            entry: FileTreeEntry(name: name, path: path, kind: isDirectory ? .directory : .file),
            parent: nil,
            resourceContextID: nil
        )
    }

    /// Replaces the entry for a surviving path whose metadata changed.
    func update(entry: FileTreeEntry) {
        guard entry.path == path else { return }
        self.entry = entry
    }

    /// Whether this node's path is `other` or lies below it.
    func isDescendant(of other: FileExplorerNode) -> Bool {
        var cursor = parent
        while let node = cursor {
            if node === other { return true }
            cursor = node.parent
        }
        return false
    }
}
