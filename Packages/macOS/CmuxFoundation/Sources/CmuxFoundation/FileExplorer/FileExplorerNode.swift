import Foundation

/// A node in the file-explorer tree backing the outline view.
///
/// A mutable reference type used as an `NSOutlineView` item: its `id` is its
/// absolute `path`, and `children` is lazily populated as folders expand.
/// All access happens on the main thread (the outline view data source is not
/// `@MainActor`-annotated), so the type is intentionally not `Sendable`.
public final class FileExplorerNode: Identifiable {
    /// Stable identity for the node, equal to its absolute path.
    public let id: String
    /// Display name (last path component).
    public let name: String
    /// Absolute path of the node.
    public let path: String
    /// Whether the node is a directory.
    public let isDirectory: Bool
    /// Loaded children, or `nil` if not yet loaded.
    public var children: [FileExplorerNode]?
    /// Whether the node's children are currently loading.
    public var isLoading: Bool = false
    /// Localized error description from the most recent failed load, if any.
    public var error: String?

    /// Creates a node for a filesystem entry.
    public init(name: String, path: String, isDirectory: Bool) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    /// Whether the node can be expanded (directories only).
    public var isExpandable: Bool { isDirectory }

    /// Children sorted directories-first, then case-insensitively by name.
    public var sortedChildren: [FileExplorerNode]? {
        children?.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
