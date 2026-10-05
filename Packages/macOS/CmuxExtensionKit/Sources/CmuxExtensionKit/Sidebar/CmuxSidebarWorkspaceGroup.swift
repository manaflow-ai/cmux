import Foundation

/// A native sidebar folder grouping workspaces, rather than a filesystem directory.
public struct CmuxSidebarWorkspaceGroup: Codable, Equatable, Identifiable, Sendable {
    /// Stable native group identifier.
    public var id: UUID
    /// Current user-visible group name.
    public var name: String
    /// Whether the native group is collapsed.
    public var isCollapsed: Bool
    /// Whether the group is pinned, including an empty durable group.
    public var isPinned: Bool
    /// Current anchor workspace, if one exists.
    public var anchorWorkspaceID: UUID?
    /// Ordered member workspace identifiers from the authoritative native model.
    public var workspaceIDs: [UUID]

    /// Creates native group metadata without any filesystem mutation authority.
    ///
    /// - Parameters:
    ///   - id: Stable native group identifier.
    ///   - name: Current group name.
    ///   - isCollapsed: Native expansion state; expanded by default.
    ///   - isPinned: Native pin state; unpinned by default.
    ///   - anchorWorkspaceID: Current live anchor, if available.
    ///   - workspaceIDs: Ordered member identifiers; empty for an empty group.
    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool = false,
        isPinned: Bool = false,
        anchorWorkspaceID: UUID? = nil,
        workspaceIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.anchorWorkspaceID = anchorWorkspaceID
        self.workspaceIDs = workspaceIDs
    }
}
