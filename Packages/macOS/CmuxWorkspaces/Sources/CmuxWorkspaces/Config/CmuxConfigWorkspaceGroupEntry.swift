import Foundation

/// One per-cwd sidebar workspace group entry: optional color/icon overrides, a
/// custom `+`-button context menu, and the in-group placement of newly created
/// workspaces.
public struct CmuxConfigWorkspaceGroupEntry: Codable, Sendable, Equatable {
    public var color: String?
    public var icon: String?
    public var contextMenu: [CmuxConfigContextMenuItem]?
    /// Where a newly-created workspace lands inside the group when the user
    /// clicks the header's `+` button or invokes Cmd-N from a group member.
    /// Valid values: `"afterCurrent"` (after the current in-group workspace,
    /// falling back to top), `"top"` (immediately after the anchor), or
    /// `"end"` (after the last member). When omitted,
    /// falls back to the global default
    /// (the stored `workspaceGroups.newWorkspacePlacement` setting).
    public var newWorkspacePlacement: String?

    public init(
        color: String? = nil,
        icon: String? = nil,
        contextMenu: [CmuxConfigContextMenuItem]? = nil,
        newWorkspacePlacement: String? = nil
    ) {
        self.color = color
        self.icon = icon
        self.contextMenu = contextMenu
        self.newWorkspacePlacement = newWorkspacePlacement
    }
}
