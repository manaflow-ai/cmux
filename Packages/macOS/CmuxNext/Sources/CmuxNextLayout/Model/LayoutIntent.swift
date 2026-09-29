/// Phase of a continuous gesture.
public nonisolated enum LayoutGesturePhase: Hashable, Sendable {
    /// Live update; the model throttles these to one per display frame.
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
    /// The column now aligned at the leading viewport edge after a scroll settled.
    case scrollTo(ScreenID, column: ColumnID)
    case dropTab(TabID, DropTarget)
    /// Daemon `new-pane-right {pane, width}`.
    case newColumn(after: PaneID, width: Double)
    /// Daemon `split {pane, dir}`.
    case split(PaneID, axis: SplitAxis)
    case selectScreen(ScreenID)
}
