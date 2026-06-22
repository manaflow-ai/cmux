public import Foundation

/// Named collapsible sidebar group containing one or more workspaces.
/// The membership relation lives on `Workspace.groupId`; this struct stores
/// the group's identity, display name, collapse/pin state, optional parent
/// folder, and the explicit anchor workspace whose lifecycle gates the group
/// itself.
///
/// The anchor workspace is always a real member workspace. It is created
/// fresh when the group is created (never promoted from an existing member),
/// rendered IMPLICITLY as the group header (no separate sidebar row), and
/// when closed dissolves the group while keeping other members alive.
public struct WorkspaceGroup: Identifiable, Equatable, Sendable {
    /// The group's stable identity.
    public let id: UUID
    /// The group's display name.
    public var name: String
    /// Whether the group's member rows are collapsed in the sidebar.
    public var isCollapsed: Bool
    /// Whether the group is pinned.
    public var isPinned: Bool
    /// Parent group containing this group as a nested folder, or nil for a
    /// top-level sidebar folder.
    public var parentGroupId: UUID?
    /// Identifier of the member workspace that owns this group's lifecycle.
    /// Always present and always points to a workspace in the window's tabs
    /// whose `groupId == self.id`. Closing this workspace dissolves the group.
    public var anchorWorkspaceId: UUID
    /// Group-level color override (hex string). When nil, falls back to the
    /// cwd-config color resolved from `cmux.json` for the anchor's cwd, then
    /// to no tint.
    public var customColor: String?
    /// SF symbol name for the header icon. When nil, defaults to `folder.fill`.
    public var iconSymbol: String?

    /// Creates a workspace group value.
    ///
    /// - Parameter id: Stable group identity.
    /// - Parameter name: Display name shown in the sidebar.
    /// - Parameter isCollapsed: Whether child rows are hidden in the sidebar.
    /// - Parameter isPinned: Whether this folder participates in its pin tier.
    /// - Parameter parentGroupId: Containing folder, or nil for a root folder.
    /// - Parameter anchorWorkspaceId: Member workspace that renders the header.
    /// - Parameter customColor: Optional group-level color override.
    /// - Parameter iconSymbol: Optional SF Symbol name for the header icon.
    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        parentGroupId: UUID? = nil,
        anchorWorkspaceId: UUID,
        customColor: String?,
        iconSymbol: String?
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.parentGroupId = parentGroupId
        self.anchorWorkspaceId = anchorWorkspaceId
        self.customColor = customColor
        self.iconSymbol = iconSymbol
    }
}
