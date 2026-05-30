// SPDX-License-Identifier: MIT

/// Full structured snapshot of the surface's currently visible grid.
/// `semanticAvailable` (D27) is `true` iff any row contains a cell with
/// a non-nil ``Cell/semantic``. Computed by the bridge in Phase 1; here
/// the type is purely declarative.
public struct CellGrid: Hashable, Sendable, Codable {
    /// Number of columns in the grid.
    public let cols: Int
    /// Number of rows in the grid.
    public let rows: Int
    /// Whether the alt screen is currently active.
    public let altScreen: Bool
    /// Window/tab title for the surface, if any.
    public let title: String?
    /// Cursor state at the moment of the read.
    public let cursor: CursorState
    /// `true` iff any cell carries a non-nil ``Cell/semantic`` (D27).
    public let semanticAvailable: Bool
    /// Row data, top to bottom.
    public let rowsData: [CellRow]

    /// Creates a grid snapshot.
    public init(
        cols: Int,
        rows: Int,
        altScreen: Bool,
        title: String?,
        cursor: CursorState,
        semanticAvailable: Bool,
        rowsData: [CellRow]
    ) {
        self.cols = cols
        self.rows = rows
        self.altScreen = altScreen
        self.title = title
        self.cursor = cursor
        self.semanticAvailable = semanticAvailable
        self.rowsData = rowsData
    }

    enum CodingKeys: String, CodingKey {
        case cols, rows
        case altScreen = "alt_screen"
        case title, cursor
        case semanticAvailable = "semantic_available"
        case rowsData = "rows_data"
    }
}
