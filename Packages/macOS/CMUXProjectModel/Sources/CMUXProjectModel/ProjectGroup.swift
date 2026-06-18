import Foundation

/// A folder node in the project navigator tree.
///
/// A group corresponds to one row in Xcode's left sidebar above its files.
/// Groups may be purely virtual (no on-disk directory), backed by a real
/// directory (``ProjectGroupStyle/folderRef``), or backed by an Xcode 16+
/// synchronized root (``ProjectGroupStyle/synchronized``). The UI does not
/// distinguish these by default; see ``ProjectGroupStyle`` for the cases
/// surfaced behind a "Raw" toggle.
public struct ProjectGroup: Sendable, Hashable, Identifiable {
    public let id: ProjectNodeID
    public let displayName: String
    public let resolvedPath: URL?
    public let style: ProjectGroupStyle
    public let children: [ProjectNodeKind]

    public init(
        id: ProjectNodeID,
        displayName: String,
        resolvedPath: URL?,
        style: ProjectGroupStyle,
        children: [ProjectNodeKind]
    ) {
        self.id = id
        self.displayName = displayName
        self.resolvedPath = resolvedPath
        self.style = style
        self.children = children
    }
}
