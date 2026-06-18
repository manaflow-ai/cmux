/// The terminal grid size of a pane's selected surface, as the app target
/// exposes it to ``ControlCommandCoordinator`` for the `pane.list` payload.
///
/// Read from the selected surface's live Ghostty surface (only present when the
/// surface is live and reports positive dimensions, matching the legacy body's
/// guard). The coordinator emits each field as a JSON integer.
public struct ControlPaneGridSize: Sendable, Equatable {
    /// The number of columns.
    public let columns: Int
    /// The number of rows.
    public let rows: Int
    /// The cell width, in pixels.
    public let cellWidthPx: Int
    /// The cell height, in pixels.
    public let cellHeightPx: Int

    /// Creates a grid size.
    ///
    /// - Parameters:
    ///   - columns: The number of columns.
    ///   - rows: The number of rows.
    ///   - cellWidthPx: The cell width, in pixels.
    ///   - cellHeightPx: The cell height, in pixels.
    public init(columns: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int) {
        self.columns = columns
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
    }
}
