/// Immutable input rendered by one stable sidebar table-cell root.
@MainActor
struct SidebarWorkspaceTableCellState {
    let row: SidebarWorkspaceTableRowConfiguration
    let isPointerHovering: Bool
    let contextMenuActions: SidebarWorkspaceTableContextMenuActions
}
