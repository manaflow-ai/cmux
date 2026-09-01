/// A terminal grid measured in columns and rows.
public struct TuiManualIOGrid: Equatable, Sendable {
    /// Number of columns in the grid.
    public var cols: Int
    /// Number of rows in the grid.
    public var rows: Int

    /// Creates a grid. Callers should pass positive dimensions.
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}
