public import CmuxNextDesign

/// Docked columns (plans/cmux-next/dock-column.md). The daemon's
/// workspace store owns the flag (OWNERSHIP-PRINCIPLES.md): the model only
/// validates a change and emits the intent; the layout changes when the
/// daemon's snapshot carries it. No optimistic copy.
extension LayoutModel {
    /// Why a column cannot become docked or change its dock.
    public enum DockRefusal: Hashable, Sendable {
        /// No screen shows a column with that id.
        case unknownColumn
        /// The change would leave no column to scroll.
        case lastScrollingColumn
        /// The column already has that state.
        case unchanged
    }

    /// The column holding `pane` and its docked state (the implicit column
    /// of a screen stored as one split tree).
    public func dockColumn(containing pane: PaneID) -> LayoutColumn? {
        screen(containing: pane)?.column(containing: pane)
    }

    /// Checks a change the way the daemon does before sending it.
    public func validateDock(_ dock: DockColumn?, for column: ColumnID) -> DockRefusal? {
        guard let screen = screens.first(where: { $0.column(id: column) != nil }),
              let current = screen.column(id: column) else { return .unknownColumn }
        guard current.dock != dock else { return .unchanged }
        // The implicit column is a screen's only column: it must scroll.
        if column == screen.implicitColumnID { return .lastScrollingColumn }
        let next = screen.layout.settingDock(dock, for: column)
        guard next.columns.contains(where: { $0.dock == nil }) else { return .lastScrollingColumn }
        return nil
    }

    /// Asks the daemon to make `column` docked at `dock`'s edge and mode,
    /// or scrolling for nil; the command carries `transaction`. Returns the
    /// refusal instead when the change is not allowed.
    @discardableResult
    public func setColumnDock(_ column: ColumnID, _ dock: DockColumn?, transaction: LayoutTransactionID = .make()) -> DockRefusal? {
        if let refusal = validateDock(dock, for: column) { return refusal }
        guard let anyPane = screens.lazy.compactMap({ $0.layout.columns.first { $0.id == column }?.root.panes.first }).first else {
            return .unknownColumn
        }
        emit(.setColumnDock(column, anyPane: anyPane, dock: dock, transaction: transaction))
        return nil
    }

    /// cmux.json `layout.stripScrollbar`, or the pin for tests and the demo.
    public var stripScrollbar: StripScrollbarMode {
        stripScrollbarOverride ?? (followsDesignMetrics ? DesignSettings.shared.stripScrollbar : .auto)
    }
}
