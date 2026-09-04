import CmuxWorkspaces

/// The value snapshot the checklist popover renders (Equatable so the
/// NSPopover host only rebuilds content when it actually changes).
struct SidebarWorkspaceChecklistPopoverModel: Equatable {
    let workspaceTitle: String
    let items: [WorkspaceChecklistItem]
    let completedCount: Int
    let totalCount: Int
    /// Bumped by the container when "Add Checklist Item…" wants the add
    /// field armed on open.
    let addFieldActivationToken: Int
    /// Whether the remote controls flag allows adding new checklist items.
    let canAddItems: Bool
}
