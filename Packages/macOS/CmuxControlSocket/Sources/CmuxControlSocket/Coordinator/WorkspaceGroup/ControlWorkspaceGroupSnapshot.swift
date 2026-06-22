public import Foundation

/// A read-only snapshot of one workspace group, as the app target exposes it to
/// ``ControlCommandCoordinator`` through ``ControlWorkspaceGroupContext``.
///
/// Mirrors the app target's `WorkspaceGroup` (plus its computed membership)
/// without the package importing the app target. The coordinator turns each
/// snapshot into the `workspace.group.*` group payload, minting the
/// `workspace_group` / `workspace` refs itself (the legacy
/// `v2WorkspaceGroupPayload` did the minting inline).
public struct ControlWorkspaceGroupSnapshot: Sendable, Equatable {
    /// The group's stable identifier.
    public let id: UUID
    /// The group's display name.
    public let name: String
    /// Whether the group is collapsed in the sidebar.
    public let isCollapsed: Bool
    /// Whether the group is pinned.
    public let isPinned: Bool
    /// Parent workspace group identifier when this group is nested.
    public let parentGroupID: UUID?
    /// The anchor workspace's identifier.
    public let anchorWorkspaceID: UUID
    /// The group's custom color override, if any.
    public let customColor: String?
    /// The group's custom icon symbol, if any.
    public let iconSymbol: String?
    /// The group's member workspace identifiers, in tab order.
    public let memberWorkspaceIDs: [UUID]

    /// Creates a workspace-group snapshot.
    ///
    /// - Parameters:
    ///   - id: The group's stable identifier.
    ///   - name: The group's display name.
    ///   - isCollapsed: Whether the group is collapsed.
    ///   - isPinned: Whether the group is pinned.
    ///   - parentGroupID: The parent workspace group identifier, if nested.
    ///   - anchorWorkspaceID: The anchor workspace's identifier.
    ///   - customColor: The custom color override, if any.
    ///   - iconSymbol: The custom icon symbol, if any.
    ///   - memberWorkspaceIDs: The member workspace identifiers, in tab order.
    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        parentGroupID: UUID? = nil,
        anchorWorkspaceID: UUID,
        customColor: String?,
        iconSymbol: String?,
        memberWorkspaceIDs: [UUID]
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.parentGroupID = parentGroupID
        self.anchorWorkspaceID = anchorWorkspaceID
        self.customColor = customColor
        self.iconSymbol = iconSymbol
        self.memberWorkspaceIDs = memberWorkspaceIDs
    }
}
