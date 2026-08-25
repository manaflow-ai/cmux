import Foundation

/// Cached Canvas metrics keyed by the remote grid dimensions and available size.
struct HiveTerminalGridMetricsCache {
    let columns: Int
    let rows: Int
    let available: CGSize
    let metrics: HiveTerminalGridMetrics

    func matches(columns: Int, rows: Int, available: CGSize) -> Bool {
        self.columns == columns && self.rows == rows && self.available == available
    }
}
