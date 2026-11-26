/// The terminal grid size of a pane's selected surface, as the app target
/// exposes it to ``ControlCommandCoordinator`` for the `pane.list` payload.
///
/// Read from the selected surface's live Ghostty surface (only present when the
/// surface is live and reports positive dimensions, matching the legacy body's
/// guard). The coordinator emits grid/pixel fields as integers and calibrated
/// point fields as doubles when available.
public struct ControlPaneGridSize: Sendable, Equatable {
    /// The number of columns.
    public let columns: Int
    /// The number of rows.
    public let rows: Int
    /// The cell width, in pixels.
    public let cellWidthPx: Int
    /// The cell height, in pixels.
    public let cellHeightPx: Int
    /// The cell width in native layout points, when surface calibration is available.
    public let cellWidthPoints: Double?
    /// The cell height in native layout points, when surface calibration is available.
    public let cellHeightPoints: Double?

    /// Creates a grid size.
    ///
    /// - Parameters:
    ///   - columns: The number of columns.
    ///   - rows: The number of rows.
    ///   - cellWidthPx: The cell width, in pixels.
    ///   - cellHeightPx: The cell height, in pixels.
    ///   - cellWidthPoints: The cell width in native layout points, if calibrated.
    ///   - cellHeightPoints: The cell height in native layout points, if calibrated.
    public init(
        columns: Int,
        rows: Int,
        cellWidthPx: Int,
        cellHeightPx: Int,
        cellWidthPoints: Double? = nil,
        cellHeightPoints: Double? = nil
    ) {
        self.columns = columns
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.cellWidthPoints = cellWidthPoints
        self.cellHeightPoints = cellHeightPoints
    }
}
