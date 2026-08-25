public import Foundation

/// The sidebar identity of one workspace group: the group, the workspace that
/// backs its header row, and the name that row renders.
///
/// A group's anchor workspace has no visible name of its own — the sidebar
/// draws the group name on that row and the anchor's own title (seeded from the
/// group name at creation and never resynced) stays hidden.
public struct CommandPaletteWorkspaceGroupAnchor: Equatable, Sendable {
    /// The group's id.
    public let groupId: UUID
    /// The workspace whose row the group header replaces.
    public let anchorWorkspaceId: UUID
    /// The group name shown on the header row.
    public let name: String

    /// Creates a group anchor descriptor.
    public init(groupId: UUID, anchorWorkspaceId: UUID, name: String) {
        self.groupId = groupId
        self.anchorWorkspaceId = anchorWorkspaceId
        self.name = name
    }
}
