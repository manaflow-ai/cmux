import Observation

/// Cell-owned observable state that never reaches into a shared sidebar store.
@MainActor
@Observable
final class SidebarWorkspaceTableCellModel {
    private(set) var state: SidebarWorkspaceTableCellState?

    @discardableResult
    func configure(
        row: SidebarWorkspaceTableRowConfiguration,
        isPointerHovering: Bool,
        contextMenuActions: SidebarWorkspaceTableContextMenuActions
    ) -> Bool {
        if let state,
           state.row.id == row.id,
           state.row.hasEquivalentContent(to: row),
           state.isPointerHovering == isPointerHovering {
            return false
        }
        state = SidebarWorkspaceTableCellState(
            row: row,
            isPointerHovering: isPointerHovering,
            contextMenuActions: contextMenuActions
        )
        return true
    }
}
