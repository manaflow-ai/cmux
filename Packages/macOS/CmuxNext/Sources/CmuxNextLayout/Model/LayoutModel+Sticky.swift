public import CmuxNextDesign

/// Sticky columns (plans/cmux-next/sticky-column.md). The daemon's
/// workspace store owns the flag (OWNERSHIP-PRINCIPLES.md): the model only
/// validates a change and emits the intent; the layout changes when the
/// daemon's snapshot carries it. No optimistic copy.
extension LayoutModel {
    /// Why a column cannot become sticky or change its stickiness.
    public enum StickyRefusal: Hashable, Sendable {
        /// No screen shows a column with that id.
        case unknownColumn
        /// The change would leave no column to scroll.
        case lastScrollingColumn
        /// The column already has that state.
        case unchanged
    }

    /// The column holding `pane` and its sticky state (the implicit column
    /// of a screen stored as one split tree).
    public func stickyColumn(containing pane: PaneID) -> LayoutColumn? {
        screen(containing: pane)?.column(containing: pane)
    }

    /// Checks a change the way the daemon does before sending it.
    public func validateSticky(_ sticky: StickyColumn?, for column: ColumnID) -> StickyRefusal? {
        guard let screen = screens.first(where: { $0.column(id: column) != nil }),
              let current = screen.column(id: column) else { return .unknownColumn }
        guard current.sticky != sticky else { return .unchanged }
        // The implicit column is a screen's only column: it must scroll.
        if column == screen.implicitColumnID { return .lastScrollingColumn }
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
            return .unknownColumn
        }
        emit(.setColumnSticky(column, anyPane: anyPane, sticky: sticky, transaction: transaction))
        return nil
    }

    /// cmux.json `layout.stripScrollbar`, or the pin for tests and the demo.
    public var stripScrollbar: StripScrollbarMode {
        stripScrollbarOverride ?? (followsDesignMetrics ? DesignSettings.shared.stripScrollbar : .auto)
    }
}
