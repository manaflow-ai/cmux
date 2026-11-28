import Foundation

/// A column/row viewport dimension for a terminal, clamped to at least one of each.
///
/// Encodes to the same JSON shape the mac side speaks (`columns`/`rows`).
public struct MobileTerminalViewportSize: Codable, Equatable, Sendable {
    /// The number of columns. Always at least `1`.
    public var columns: Int
    /// The number of rows. Always at least `1`.
    public var rows: Int

    /// Creates a viewport size, clamping each dimension to a minimum of `1`.
    /// - Parameters:
    ///   - columns: The requested column count.
    ///   - rows: The requested row count.
    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}
