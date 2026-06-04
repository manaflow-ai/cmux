/// A surface's grid measurement as reported by libghostty.
public struct GhosttySurfaceMeasuredSize: Sendable, Equatable {
    /// Grid columns.
    public let columns: Int
    /// Grid rows.
    public let rows: Int
    /// Rendered width in pixels.
    public let pixelWidth: Int
    /// Rendered height in pixels.
    public let pixelHeight: Int

    /// Creates a measurement.
    /// - Parameters:
    ///   - columns: Grid columns.
    ///   - rows: Grid rows.
    ///   - pixelWidth: Rendered width in pixels.
    ///   - pixelHeight: Rendered height in pixels.
    public init(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
