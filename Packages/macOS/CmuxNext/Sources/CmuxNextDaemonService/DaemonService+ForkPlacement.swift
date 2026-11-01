public import CmuxNextDaemon

extension DaemonService {
    /// Moves an agent chat's fork, tab `surface` just opened in the chat's pane `pane`, into a new
    /// strip column beside the chat's column (`left`: before it) or, with `left` nil, a new row
    /// below the chat's row, `rowHeight` permille tall (u18673: Fork to New Column Right / Left /
    /// New Row). A column goes through `moveToColumn` (the app's tab move, which sizes the column)
    /// at the ``ForkColumnSlot``; when the slot asks, the chat's column then moves right past it.
    /// - Parameters:
    ///   - surface: The fork's tab.
    ///   - pane: The chat's pane.
    ///   - left: The column's side; nil for a row.
    ///   - rowHeight: A new row's height in permille.
    ///   - moveToColumn: Moves the tab into a new column after the given column, then reports whether it moved.
    public func placeFork(_ surface: SurfaceID, beside pane: PaneModel, left: Bool?, rowHeight: Int,
                          moveToColumn: @escaping @MainActor (ColumnID?, @escaping @MainActor (Bool) -> Void) -> Void) {
        let handle = pane.handle
        guard let left else {
            return send("new-row") { try await RowCommands($0).moveTab(surface, toNewRowBelow: handle, height: rowHeight) }
        }
        switch ForkColumnSlot(beside: pane, in: store, left: left) {
        case .after(let column): moveToColumn(column) { _ in }
        case .afterThenMoveRight(let column):
            moveToColumn(column) { [weak self] moved in
                if moved { self?.send("move-column") { try await $0.moveColumn(of: handle, direction: .right) } }
            }
        }
    }
}
