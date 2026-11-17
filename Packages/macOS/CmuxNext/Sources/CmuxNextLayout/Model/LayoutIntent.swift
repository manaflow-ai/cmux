public import CoreGraphics

/// Phase of a continuous gesture.
public nonisolated enum LayoutGesturePhase: Hashable, Sendable {
    /// Live update: applied locally, never sent as an intent.
    case changed
    /// Final value of the gesture.
    case ended
}

/// Direction for keyboard focus movement.
public nonisolated enum LayoutDirection: Hashable, Sendable, CaseIterable {
    case left, right, up, down
}

/// Things the layout wants the App (and through it, the daemon) to do.
///
/// Client-local intents (`focus`, `scrollTo`, `selectScreen`) never need a
/// daemon write for ordinary UI (docs/concepts.md, Active and Focus State);
/// they are reported so the App can move first responder and persist the
/// personal projection on settle.
public nonisolated enum LayoutIntent: Hashable, Sendable {
    case focus(PaneID)
    /// Daemon `set-split-ratio {split, ratio, transaction}`.
    case setSplitRatio(SplitID, ratio: Double, transaction: LayoutTransactionID, phase: LayoutGesturePhase)
    /// Daemon `set-viewport-pane-width {pane, width, transaction}`; `anyPane`
    /// is a pane in the column for the pane-addressed command.
    case setColumnWidth(ColumnID, anyPane: PaneID, width: Double, transaction: LayoutTransactionID, phase: LayoutGesturePhase)
    /// Daemon `set-layout-sizes {values, transaction}` (`layout-sizes-batch-v1`): the values a gesture ends
    /// with when they are more than one (a key trade's two widths, a drag release's widths and ratios), as
    /// one daemon commit, every value or none. A daemon without the capability gets each value's own
    /// command under the transaction. One reply settles the transaction.
    case setLayoutSizes([SizeValue], transaction: LayoutTransactionID)
    /// The column now aligned at the leading viewport edge after a scroll settled.
    case scrollTo(ScreenID, column: ColumnID)
    case dropTab(TabID, DropTarget)
    /// Daemon `new-pane-right {pane, width}`.
    case newColumn(after: PaneID, width: Double)
    /// Daemon `new-pane-right {pane, width, side: "left"}` (`column-left-v1`): New Column Left.
    case newColumnLeft(of: PaneID, width: Double)
    /// Daemon `split {pane, dir}`.
    case split(PaneID, axis: SplitAxis)
    case selectScreen(ScreenID)
    /// Daemon `set-column-dock {pane, dock, edge, mode, transaction}`
    /// (`dock-columns-v1`); nil makes the column scroll again.
    case setColumnDock(ColumnID, anyPane: PaneID, dock: DockColumn?, transaction: LayoutTransactionID)
    /// Daemon `set-row-heights {column, heights, fit}` (`rows-v1`): every
    /// row of the column, sent once when a row divider drag ends. Never
    /// applied locally: the App sends it through the store's intent log.
    case setRowHeights(ColumnID, heights: [RowHeight], fit: Bool)
    /// Daemon `new-row {pane, height_permille}` (`rows-v1`).
    case newRow(below: PaneID, height: Int)
    /// Daemon `float-pane {pane, mode: "on", x, y, w, h}` (`floating-panes-v1`): the frame a pointer's move or resize
    /// of a floating pane released, as fractions of the pane area. Shown at once (`LayoutModel.setFloatingFrame`).
    case setFloatingFrame(PaneID, frame: CGRect)
    /// Daemon `float-pane {pane, mode: "on"}` with no frame (`floating-panes-v1`): a floating pane that got the
    /// focus comes to the front and keeps the frame that the daemon has.
    case raiseFloatingPane(PaneID)
    /// A divider or column-edge gesture ended with no release (its target
    /// went away mid-drag): nothing more of `transaction` will be sent.
    case cancelGesture(LayoutTransactionID)

    /// The frame that a `setFloatingFrame` names. Nil for each other intent: a `raiseFloatingPane` names none.
    public var floatingFrame: CGRect? {
        if case let .setFloatingFrame(_, frame) = self { frame } else { nil }
    }

    /// The size values `self` asks the daemon to set, with their transaction: the one value of `setSplitRatio` or
    /// `setColumnWidth`, the values of `setLayoutSizes`. Nil for every other intent.
    public var sizes: (values: [SizeValue], transaction: LayoutTransactionID)? {
        switch self {
        case let .setSplitRatio(split, ratio, transaction, _):
            return ([.ratio(split, ratio)], transaction)
        case let .setColumnWidth(column, anyPane, width, transaction, _):
            return ([.width(column, anyPane: anyPane, width)], transaction)
        case let .setLayoutSizes(values, transaction):
            return (values, transaction)
        default:
            return nil
        }
    }

    /// One value of `setLayoutSizes`: what `setSplitRatio` or `setColumnWidth` names alone.
    public nonisolated enum SizeValue: Hashable, Sendable {
        case ratio(SplitID, Double)
        /// `anyPane` is a pane in the column, as in `setColumnWidth`.
        case width(ColumnID, anyPane: PaneID, Double)
    }
}
