/// A daemon-authoritative effective grid (cols × rows) the surface should be
/// pinned to, so every attached device renders the same shared grid.
public struct GhosttySurfaceGridPin: Sendable, Equatable {
    /// Pinned grid columns.
    public let columns: Int
    /// Pinned grid rows.
    public let rows: Int

    /// Creates a pin.
    /// - Parameters:
    ///   - columns: Pinned grid columns (must be positive to take effect).
    ///   - rows: Pinned grid rows (must be positive to take effect).
    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}
