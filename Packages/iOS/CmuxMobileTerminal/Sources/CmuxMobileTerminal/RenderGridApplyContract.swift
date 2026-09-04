/// Grid contract a render-grid chunk must satisfy at paint time.
///
/// Render-grid frames address absolute rows and columns of the producer's
/// grid, and a delta's scroll prologue only scrolls when the local surface's
/// bottom row is the frame's bottom row. Painting a frame onto a local grid
/// with different dimensions silently corrupts rows (the prologue stops
/// scrolling, spans truncate or clamp), and painting a delta after a local
/// resize reflowed the surface corrupts rows the delta does not repaint.
/// ``GhosttySurfaceView/processOutput`` checks this contract on the serial
/// surface queue, exactly ordered against every resize, and fails the apply
/// (caller resets and replays) instead of painting.
public struct RenderGridApplyContract: Equatable, Sendable {
    /// Frame columns the local grid must match.
    public let columns: Int
    /// Frame rows the local grid must match.
    public let rows: Int
    /// Deltas additionally require that no resize changed the grid since the
    /// previous applied render-grid frame.
    public let isDelta: Bool

    public init(columns: Int, rows: Int, isDelta: Bool) {
        self.columns = columns
        self.rows = rows
        self.isDelta = isDelta
    }
}
