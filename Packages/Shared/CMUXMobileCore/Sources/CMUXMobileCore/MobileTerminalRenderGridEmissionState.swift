/// Cached producer state used to choose the next render-grid event payload.
///
/// A producer stores this compact state instead of the full previous
/// ``MobileTerminalRenderGridFrame`` so the hot render path can diff row
/// signatures without retaining complete viewport snapshots.
public struct MobileTerminalRenderGridEmissionState: Equatable, Sendable {
    /// Number of columns in the frame that produced this state.
    public let columns: Int
    /// Number of rows in the frame that produced this state.
    public let rows: Int
    /// Terminal byte sequence covered by the frame that produced this state.
    public let stateSeq: UInt64
    /// Per-row text/style signatures from ``MobileTerminalRenderGridFrame/rowSignatures()``.
    public let rowSignatures: [String]

    /// Creates cached render-grid emission state.
    ///
    /// - Parameters:
    ///   - columns: Number of columns in the frame that produced this state.
    ///   - rows: Number of rows in the frame that produced this state.
    ///   - stateSeq: Terminal byte sequence covered by the source frame.
    ///   - rowSignatures: Per-row text/style signatures for the source frame.
    public init(
        columns: Int,
        rows: Int,
        stateSeq: UInt64,
        rowSignatures: [String]
    ) {
        self.columns = columns
        self.rows = rows
        self.stateSeq = stateSeq
        self.rowSignatures = rowSignatures
    }
}
