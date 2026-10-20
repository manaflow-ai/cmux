/// Where "Chief: Open Memory Inspector" puts its browser tab.
///
/// Outside Home the inspector gets a new column right of the focused pane's
/// column. In the home workspace it must not: the left column is the pinned
/// Chief dock (the daemon refuses a new tab there), and a new column lands
/// right of the full-width right column, off screen, so the inspector looked
/// as if it closed at once (a243). In Home the inspector is a tab in the
/// first scrolling column, the right column where Home shows pages.
/// Pure: the handler maps the live tree into `Column`s.
nonisolated enum ChiefInspectorPlacement<Pane: Hashable>: Equatable {
    /// A new tab in this pane (Home's right column).
    case tab(in: Pane)
    /// A new column right of this pane's column.
    case newColumn(rightOf: Pane)

    /// One column of the focused pane's screen, left to right.
    struct Column: Equatable {
        var panes: [Pane]
        /// Docked to an edge (the Home Chief dock or a tool dock): never takes the tab.
        var isDock: Bool
    }

    /// The placement for an inspector opened while `focused` has focus.
    /// `nil`: the home workspace has no scrolling column; the caller then
    /// uses a user workspace.
    static func resolve(focused: Pane, inHome: Bool, columns: [Column]) -> ChiefInspectorPlacement? {
        // The behavior before a243: always a new column, Home or not.
        .newColumn(rightOf: focused)
    }
}
