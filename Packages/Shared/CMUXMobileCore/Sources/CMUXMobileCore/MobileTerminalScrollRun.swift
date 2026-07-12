/// One direction-preserving terminal scroll run. Opposite signs remain
/// distinct because viewport clamping and alternate-screen wheel delivery make
/// algebraic cancellation observably incorrect.
public struct MobileTerminalScrollRun: Codable, Equatable, Sendable {
    /// Capability advertised by hosts that execute ordered run batches.
    public static let orderedRunsCapability = "terminal.scroll.ordered_runs.v1"

    /// Maximum ordered runs accepted in one host RPC.
    public static let maximumOrderedBatchCount = 32

    public var lines: Double
    public var col: Int
    public var row: Int

    public init(lines: Double, col: Int, row: Int) {
        self.lines = lines
        self.col = max(0, col)
        self.row = max(0, row)
    }
}
