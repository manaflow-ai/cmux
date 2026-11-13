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

    /// The first pane of the scrolling column right of `pane` (for a pane in a dock, the strip's
    /// first column), as `cmux identify`'s `beside` names it; nil when there is none.
    /// - Parameter pane: The pane a tab opens beside (an agent chat's).
    /// - Returns: The pane that takes the tab, or nil.
    public func scrollingPane(beside pane: PaneModel) -> PaneModel? {
        let columns = screenColumns(holding: pane)
        guard let index = columns.firstIndex(where: { $0.layout.paneIDs.contains(pane.handle) }) else { return nil }
        // Right of a scrolling column: the columns after it; beside a dock: the whole strip.
        let docked = columns.dropFirst(index).first?.dock != nil
        let candidates = columns.dropFirst(docked ? 0 : index + 1)
        guard let column = candidates.first(where: { $0.dock == nil && !$0.layout.paneIDs.contains(pane.handle) }),
              let first = column.layout.paneIDs.first else { return nil }
        return self.pane(first)
    }

    /// The columns of the screen showing `pane`, left to right; empty when no screen shows it.
    /// - Parameter pane: A pane of this store.
    /// - Returns: The screen's columns.
    public func screenColumns(holding pane: PaneModel) -> [ColumnSnapshot] {
        workspace(containing: pane.handle)?.screens.first { $0.panes.contains { $0 === pane } }?.columns ?? []
    }
}
