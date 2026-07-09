/// A single directory entry surfaced by a ``FileExplorerProvider``.
///
/// A pure value describing one filesystem child: its display `name`, absolute
/// `path`, and whether it is a directory. Carries no live state, so it crosses
/// actor and task boundaries freely.
public struct FileExplorerEntry: Sendable {
    /// Display name of the entry (last path component).
    public let name: String
    /// Absolute path of the entry.
    public let path: String
    /// Whether the entry is a directory.
    public let isDirectory: Bool

    /// Creates a directory entry.
    public init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }
}
