extension DaemonStore {
    /// The scrolling column holding `pane`: the column a tab opened beside it follows, so a new
    /// column opens right of it, where the pane keeping focus keeps it in view. The daemon's default
    /// is after the last column, past the panes already beside it and off screen (cx-u1yn). Nil for
    /// a pane in a docked column or on a screen without columns.
    /// - Parameter pane: The pane a new column opens beside (an agent chat's, a link's source).
    /// - Returns: Its column's handle, or nil.
    public func scrollingColumn(holding pane: PaneModel) -> ColumnID? {
        guard let column = screenColumns(holding: pane).first(where: { $0.layout.paneIDs.contains(pane.handle) }),
              column.dock == nil else { return nil }
        return column.id
    }

    /// The columns of the screen showing `pane`, left to right; empty when no screen shows it.
    /// - Parameter pane: A pane of this store.
    /// - Returns: The screen's columns.
    public func screenColumns(holding pane: PaneModel) -> [ColumnSnapshot] {
        workspace(containing: pane.handle)?.screens.first { $0.panes.contains { $0 === pane } }?.columns ?? []
    }
}
