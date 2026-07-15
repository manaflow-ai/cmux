/// One direction-preserving terminal scroll run. Opposite signs remain
/// distinct because viewport clamping and alternate-screen wheel delivery make
/// algebraic cancellation observably incorrect.
public struct MobileTerminalScrollRun: Codable, Equatable, Sendable {
    /// Capability advertised by hosts that execute ordered run batches.
    public static let orderedRunsCapability = "terminal.scroll.ordered_runs.v1"

    /// Maximum ordered runs accepted in one host RPC.
    public static let maximumOrderedBatchCount = 32

    /// Signed line delta, preserving gesture direction.
    public var lines: Double
    /// Exact signed rows for normal-screen scrollback. `nil` identifies a
    /// legacy producer; alternate-screen applications always consume `lines`.
    public var primaryRows: Int?
    /// Terminal column where the scroll occurred.
    public var col: Int
    /// Terminal row where the scroll occurred.
    public var row: Int

    /// Creates a scroll run and clamps its coordinates to nonnegative values.
    public init(lines: Double, col: Int, row: Int) {
        self.lines = lines
        self.primaryRows = nil
        self.col = max(0, col)
        self.row = max(0, row)
    }

    /// Creates one mode-aware scroll run. Positive values scroll upward.
    public init(primaryRows: Int, alternateScreenLines: Double, col: Int, row: Int) {
        self.lines = alternateScreenLines
        self.primaryRows = primaryRows
        self.col = max(0, col)
        self.row = max(0, row)
    }

    /// Direction used for batching and directional prefetch.
    public var directionValue: Double {
        if let primaryRows, primaryRows != 0 { return Double(primaryRows) }
        return lines
    }

    /// Physical viewport distance used to schedule bounded prefetch refreshes.
    public var prefetchDistanceRows: Double {
        if let primaryRows { return Double(abs(primaryRows)) }
        return abs(lines)
    }

    public var hasEffect: Bool {
        (primaryRows.map { $0 != 0 } ?? false) || lines != 0
    }

    /// Drops exact-row semantics for hosts that predate ordered scroll runs.
    /// The returned run matches the scalar wheel-distance behavior those hosts
    /// execute, so local optimistic rendering cannot diverge from the Mac.
    public var legacyCompatible: Self {
        guard primaryRows != nil else { return self }
        return Self(lines: lines, col: col, row: row)
    }

    /// Combines two already-validated, direction-compatible runs.
    public mutating func merge(_ newer: Self) {
        lines += newer.lines
        switch (primaryRows, newer.primaryRows) {
        case (.some(let olderRows), .some(let newerRows)):
            primaryRows = olderRows + newerRows
        case (.none, .none):
            break
        case (.some, .none), (.none, .some):
            preconditionFailure("cannot merge exact and legacy terminal scroll runs")
        }
        col = newer.col
        row = newer.row
    }
}
