/// Where a new strip column for a fork of a chat opens, beside the chat's column `own`.
///
/// The daemon inserts a new column after a named column (`move-tab-to-column`'s
/// `afterColumn`). Right of the chat is after its own column. Left of the chat is after the
/// column before it; with none (the chat's column is first) or a docked one before it, the new
/// column goes after the chat's and the chat's column then moves right past it (`move-column`).
public enum ForkColumnSlot: Equatable, Sendable {
    /// Insert after this column; nil lets the daemon place it (after the last column).
    case after(ColumnID?)
    /// Insert after `own`, then move `own`'s column one place right.
    case afterThenMoveRight(ColumnID)

    /// The slot for a new column right (or, with `left`, left) of column `own` among `columns`.
    /// - Parameters:
    ///   - columns: The screen's columns, left to right.
    ///   - own: The chat's scrolling column; nil when it has none (a docked chat).
    ///   - left: Whether the column opens before the chat's.
    public init(columns: [ColumnSnapshot], own: ColumnID?, left: Bool) {
        guard left, let own else { self = .after(own); return }
        if let previous = zip(columns.dropFirst(), columns).first(where: { $0.0.id == own })?.1, previous.dock == nil {
            self = .after(previous.id)
        } else {
            self = .afterThenMoveRight(own)
        }
    }

    /// The slot for a new column beside `pane`'s column in `store`.
    /// - Parameters:
    ///   - pane: The chat's pane.
    ///   - store: The store listing it.
    ///   - left: Whether the column opens before the chat's.
    @MainActor public init(beside pane: PaneModel, in store: DaemonStore, left: Bool) {
        self.init(columns: store.screenColumns(holding: pane), own: store.scrollingColumn(holding: pane), left: left)
    }
}
