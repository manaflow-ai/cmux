/// A cell grid sampled from the native Ghostty pane.
struct CloudTuiManualIOGrid: Equatable, Sendable {
    let columns: Int
    let rows: Int

    /// Creates a bounded, usable terminal grid.
    init?(columns: Int, rows: Int) {
        guard (2...10_000).contains(columns), (2...10_000).contains(rows) else {
            return nil
        }
        self.columns = columns
        self.rows = rows
    }
}
