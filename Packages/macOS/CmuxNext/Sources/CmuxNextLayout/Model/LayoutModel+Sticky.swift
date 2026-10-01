public import CmuxNextDesign

/// Sticky columns (plans/cmux-next/sticky-column.md). The daemon owns the
/// flag; the model applies the change optimistically under a transaction
/// until the daemon accepts (next snapshot wins) or rejects it.
extension LayoutModel {
    struct StickyOverride {
        var value: StickyColumn?
        var transaction: LayoutTransactionID
        var settled = false
    }

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

    /// Makes `column` sticky at `sticky`'s edge and mode, or scrolling for
    /// nil. Applied at once; the daemon command carries `transaction`.
    /// Returns the refusal instead when the change is not allowed.
    @discardableResult
    public func setColumnSticky(_ column: ColumnID, _ sticky: StickyColumn?, transaction: LayoutTransactionID = .make()) -> StickyRefusal? {
        if let refusal = validateSticky(sticky, for: column) { return refusal }
        guard let anyPane = screens.lazy.compactMap({ $0.layout.columns.first { $0.id == column }?.root.panes.first }).first else {
            return .notColumns
        }
        stickyOverrides[column] = StickyOverride(value: sticky, transaction: transaction)
        updateScreens { $0.settingSticky(sticky, for: column) }
        emit(.setColumnSticky(column, anyPane: anyPane, sticky: sticky, transaction: transaction))
        return nil
    }

    /// Applies pending sticky overrides onto a daemon layout; an override
    /// the daemon already reports is confirmed and dropped.
    func overlaidSticky(_ layout: ScreenLayout) -> ScreenLayout {
        var layout = layout
        for (column, override) in stickyOverrides {
            guard let incoming = layout.columns.first(where: { $0.id == column }) else { continue }
            if incoming.sticky == override.value {
                stickyOverrides[column] = nil
            } else {
                layout = layout.settingSticky(override.value, for: column)
            }
        }
        return layout
    }

    /// cmux.json `layout.stripScrollbar`, or the pin for tests and the demo.
    public var stripScrollbar: StripScrollbarMode {
        stripScrollbarOverride ?? (followsDesignMetrics ? DesignSettings.shared.stripScrollbar : .auto)
    }
}
