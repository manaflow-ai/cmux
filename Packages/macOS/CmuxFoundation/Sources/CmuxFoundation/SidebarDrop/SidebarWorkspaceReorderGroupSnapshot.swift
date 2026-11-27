public import Foundation

/// Immutable workspace group data used by the sidebar workspace reorder resolver.
public struct SidebarWorkspaceReorderGroupSnapshot: Equatable, Sendable {
    /// The group identifier.
    public let id: UUID

    /// The workspace id rendered as the group's header row.
    public let anchorWorkspaceId: UUID

    /// Whether the group belongs to the leading pinned tier.
    public let isPinned: Bool

    /// Whether the group currently has no live workspace member.
    public let isEmpty: Bool

    /// Creates a workspace group snapshot for sidebar reorder planning.
    ///
    /// - Parameters:
    ///   - id: The group identifier.
    ///   - anchorWorkspaceId: The workspace id rendered as the group's header row.
    ///   - isPinned: Whether the group belongs to the leading pinned tier.
    ///   - isEmpty: Whether the group is represented by a header-only row.
    public init(id: UUID, anchorWorkspaceId: UUID, isPinned: Bool, isEmpty: Bool = false) {
        self.id = id
        self.anchorWorkspaceId = anchorWorkspaceId
        self.isPinned = isPinned
        self.isEmpty = isEmpty
    }
}
