public import CmuxNextDesign

/// Sticky columns (plans/cmux-next/sticky-column.md). The daemon's
/// workspace store owns the flag (OWNERSHIP-PRINCIPLES.md): the model only
/// validates a change and emits the intent; the layout changes when the
/// daemon's snapshot carries it. No optimistic copy.
extension LayoutModel {
    /// Why a column cannot become sticky or change its stickiness.
    public enum StickyRefusal: Hashable, Sendable {
        /// The screen does not scroll columns (one tiled split tree).
        case notColumns
        /// The change would leave no column to scroll.
        case lastScrollingColumn
        /// The column already has that state.
        case unchanged
    }

    /// The column holding `pane` and its sticky state, on a columns screen.
    public func stickyColumn(containing pane: PaneID) -> LayoutColumn? {
        screen(containing: pane)?.layout.column(containing: pane)
    }

    /// Checks a change the way the daemon does before sending it.
    public func validateSticky(_ sticky: StickyColumn?, for column: ColumnID) -> StickyRefusal? {
        guard let screen = screens.first(where: { $0.layout.columns.contains { $0.id == column } }),
              let current = screen.layout.columns.first(where: { $0.id == column }) else { return .notColumns }
        guard current.sticky != sticky else { return .unchanged }
        let next = screen.layout.settingSticky(sticky, for: column)
        guard next.columns.contains(where: { $0.sticky == nil }) else { return .lastScrollingColumn }
        return nil
    }

    /// Asks the daemon to make `column` sticky at `sticky`'s edge and mode,
    /// or scrolling for nil; the command carries `transaction`. Returns the
    /// refusal instead when the change is not allowed.
    @discardableResult
    public func setColumnSticky(_ column: ColumnID, _ sticky: StickyColumn?, transaction: LayoutTransactionID = .make()) -> StickyRefusal? {
        if let refusal = validateSticky(sticky, for: column) { return refusal }
        guard let anyPane = screens.lazy.compactMap({ $0.layout.columns.first { $0.id == column }?.root.panes.first }).first else {
            return .notColumns
        }
        emit(.setColumnSticky(column, anyPane: anyPane, sticky: sticky, transaction: transaction))
        return nil
    }

    /// cmux.json `layout.stripScrollbar`, or the pin for tests and the demo.
    public var stripScrollbar: StripScrollbarMode {
        stripScrollbarOverride ?? (followsDesignMetrics ? DesignSettings.shared.stripScrollbar : .auto)
    }
}
