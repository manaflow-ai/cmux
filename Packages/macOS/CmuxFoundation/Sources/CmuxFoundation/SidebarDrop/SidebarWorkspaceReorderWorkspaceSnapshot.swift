public import Foundation

/// Immutable workspace data used by the sidebar workspace reorder resolver.
public struct SidebarWorkspaceReorderWorkspaceSnapshot: Equatable, Sendable {
    /// The workspace identifier.
    public let id: UUID

    /// Whether the workspace belongs to the leading pinned tier.
    public let isPinned: Bool

    /// The group containing this workspace, or `nil` for a root-level workspace.
    public let groupId: UUID?

    /// Creates a workspace snapshot for sidebar reorder planning.
    ///
    /// - Parameters:
    ///   - id: The workspace identifier.
    ///   - isPinned: Whether the workspace belongs to the leading pinned tier.
    ///   - groupId: The group containing this workspace, or `nil` for a root-level workspace.
    public init(id: UUID, isPinned: Bool, groupId: UUID?) {
        self.id = id
        self.isPinned = isPinned
        self.groupId = groupId
    }
}
