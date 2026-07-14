/// Constant-memory accumulator that preserves physical row distance separately
/// from alternate-screen wheel ticks across display-link frames.
public struct MobileTerminalScrollInputAccumulator: Sendable {
    public private(set) var pendingPrimaryRows: Double = 0
    private var pendingAlternateScreenLines: Double = 0

    public init() {}

    public func wouldReverse(primaryRows: Double, alternateScreenLines: Double) -> Bool {
        Self.haveOppositeSigns(pendingPrimaryRows, primaryRows)
            || Self.haveOppositeSigns(pendingAlternateScreenLines, alternateScreenLines)
    }

    public mutating func accumulate(primaryRows: Double, alternateScreenLines: Double) {
        guard primaryRows.isFinite, alternateScreenLines.isFinite else {
            reset()
            return
        }
        pendingPrimaryRows += primaryRows
        pendingAlternateScreenLines += alternateScreenLines
    }

    public mutating func drain(col: Int, row: Int) -> MobileTerminalScrollRun? {
        let nearestInteger = pendingPrimaryRows.rounded()
        let normalizedRows = abs(pendingPrimaryRows - nearestInteger) < 0.000_000_001
            ? nearestInteger
            : pendingPrimaryRows
        let integralRows = normalizedRows.rounded(.towardZero)
        let primaryRows = Int(integralRows)
        let alternateScreenLines = pendingAlternateScreenLines
        guard primaryRows != 0 || alternateScreenLines != 0 else { return nil }
        pendingPrimaryRows = normalizedRows - integralRows
        pendingAlternateScreenLines = 0
        return MobileTerminalScrollRun(
            primaryRows: primaryRows,
            alternateScreenLines: alternateScreenLines,
            col: col,
            row: row
        )
    }

    public mutating func reset() {
        pendingPrimaryRows = 0
        pendingAlternateScreenLines = 0
    }

    private static func haveOppositeSigns(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs != 0 && rhs != 0 && lhs.sign != rhs.sign
    }
}
