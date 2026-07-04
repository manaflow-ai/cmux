public import Foundation

/// Immutable workspace group data used by the sidebar workspace reorder resolver.
public struct SidebarWorkspaceReorderGroupSnapshot: Equatable, Sendable {
    /// The group identifier.
    public let id: UUID

    /// The workspace id rendered as the group's header row.
    public let anchorWorkspaceId: UUID

    /// Whether the group belongs to the leading pinned tier.
    public let isPinned: Bool

    /// Parent group containing this group, or `nil` for a root-level group.
    public let parentGroupId: UUID?

    /// Creates a workspace group snapshot for sidebar reorder planning.
    ///
    /// - Parameters:
    ///   - id: The group identifier.
    ///   - anchorWorkspaceId: The workspace id rendered as the group's header row.
    ///   - isPinned: Whether the group belongs to the leading pinned tier.
    ///   - parentGroupId: Parent group containing this group, or `nil` for a root-level group.
    public init(id: UUID, anchorWorkspaceId: UUID, isPinned: Bool, parentGroupId: UUID? = nil) {
        self.id = id
        self.anchorWorkspaceId = anchorWorkspaceId
        self.isPinned = isPinned
        self.parentGroupId = parentGroupId
    }
}
