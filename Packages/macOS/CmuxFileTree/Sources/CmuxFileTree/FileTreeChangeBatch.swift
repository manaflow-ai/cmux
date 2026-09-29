/// Directories whose contents changed, coalesced over one delivery window.
///
/// A batch names directories, not files: the tree re-lists a changed directory
/// only when it is loaded, so churn inside collapsed or never-opened folders
/// (a build writing `node_modules` or `.build`) costs one set lookup per path.
public struct FileTreeChangeBatch: Sendable, Equatable {
    /// Directories whose direct children may have changed.
    public var directories: Set<String>
    /// Directories whose whole subtree must be re-listed because the event
    /// source dropped events (FSEvents `MustScanSubDirs`, a kernel overflow).
    public var subtrees: Set<String>

    /// Creates a batch.
    /// - Parameters:
    ///   - directories: Directories whose direct children changed.
    ///   - subtrees: Directories whose entire subtree is stale.
    public init(directories: Set<String> = [], subtrees: Set<String> = []) {
        self.directories = directories
        self.subtrees = subtrees
    }

    /// Whether the batch names nothing.
    public var isEmpty: Bool { directories.isEmpty && subtrees.isEmpty }

    /// Adds another batch's directories to this one.
    /// - Parameter other: The batch to merge.
    public mutating func formUnion(_ other: FileTreeChangeBatch) {
        directories.formUnion(other.directories)
        subtrees.formUnion(other.subtrees)
    }
}
