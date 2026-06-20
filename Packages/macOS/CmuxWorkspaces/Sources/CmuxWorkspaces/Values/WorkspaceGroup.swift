public import Foundation

/// Named collapsible sidebar group containing one or more workspaces.
/// The membership relation lives on `Workspace.groupId`; this struct stores
/// the group's identity, display name, collapse/pin state, and the explicit
/// anchor workspace used to position the group in workspace order.
///
/// The anchor workspace is always a real member workspace. Creating a group
/// promotes the first selected child to be the anchor; it does not create a
/// separate terminal workspace for the folder header.
public struct WorkspaceGroup: Identifiable, Equatable, Sendable {
    /// The group's stable identity.
    public let id: UUID
    /// The group's display name.
    public var name: String
    /// Whether the group's member rows are collapsed in the sidebar.
    public var isCollapsed: Bool
    /// Whether the group is pinned.
    public var isPinned: Bool
    /// Identifier of the member workspace that positions this group.
    /// Always present and always points to a workspace in the window's tabs
    /// whose `groupId == self.id`. Closing this workspace dissolves the group.
    public var anchorWorkspaceId: UUID
    /// Group-level color override (hex string). When nil, falls back to the
    /// cwd-config color resolved from `cmux.json` for the anchor's cwd, then
    /// to no tint.
    public var customColor: String?
    /// SF symbol name for the header icon. When nil, defaults to `folder.fill`.
    public var iconSymbol: String?

    /// Creates a group (memberwise; mirrors the legacy app-side shape).
    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        anchorWorkspaceId: UUID,
        customColor: String?,
        iconSymbol: String?
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.anchorWorkspaceId = anchorWorkspaceId
        self.customColor = customColor
        self.iconSymbol = iconSymbol
    }
}
