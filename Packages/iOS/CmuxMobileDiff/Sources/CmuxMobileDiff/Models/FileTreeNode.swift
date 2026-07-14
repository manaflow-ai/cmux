internal import CmuxMobileRPC

/// One compressed directory or file node in the changed-file tree.
struct FileTreeNode: Identifiable, Sendable, Equatable {
    /// Node classification used for directory-first sorting.
    enum Kind: Sendable, Equatable {
        /// A directory, possibly compressed with single-child descendants.
        case directory
        /// A changed file leaf.
        case file
    }

    /// Full repository-relative path and stable identity.
    let id: String
    /// Display component, including compressed directory chains.
    let name: String
    /// Node classification.
    let kind: Kind
    /// Sorted child nodes for a directory.
    let children: [FileTreeNode]
    /// Wire file summary for a leaf.
    let file: MobileChangesFile?
    /// Whether the leaf's current patch digest is marked viewed.
    let isViewed: Bool

    /// Creates a file-tree node.
    init(
        id: String,
        name: String,
        kind: Kind,
        children: [FileTreeNode],
        file: MobileChangesFile?,
        isViewed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.children = children
        self.file = file
        self.isViewed = isViewed
    }
}
