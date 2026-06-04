/// The visible cursor position used while terminal keyboard copy mode is active.
public struct TerminalKeyboardCopyModeCursor: Equatable, Sendable {
    /// The zero-based viewport row occupied by the cursor.
    public var row: Int

    /// The zero-based viewport column occupied by the cursor.
    public var column: Int

    /// Creates a cursor at a viewport cell.
    ///
    /// - Parameters:
    ///   - row: The zero-based viewport row.
    ///   - column: The zero-based viewport column.
    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// Returns a cursor constrained to the supplied grid dimensions.
    ///
    /// - Parameters:
    ///   - rows: The current terminal viewport row count.
    ///   - columns: The current terminal viewport column count.
    /// - Returns: A copy of this cursor clamped into the grid.
    public func clamped(rows: Int, columns: Int) -> TerminalKeyboardCopyModeCursor {
        var copy = self
        copy.clamp(rows: rows, columns: columns)
        return copy
    }

    /// Constrains the cursor to the supplied grid dimensions.
    ///
    /// - Parameters:
    ///   - rows: The current terminal viewport row count.
    ///   - columns: The current terminal viewport column count.
    public mutating func clamp(rows: Int, columns: Int) {
        row = Self.clamp(row, upperBound: rows)
        column = Self.clamp(column, upperBound: columns)
    }

    /// Moves the cursor within the current grid and reports any vertical scroll overflow.
    ///
    /// - Parameters:
    ///   - direction: The movement to apply.
    ///   - count: The repeat count from a numeric prefix.
    ///   - rows: The current terminal viewport row count.
    ///   - columns: The current terminal viewport column count.
    /// - Returns: A signed line delta to apply to the viewport when movement crossed a vertical edge.
    public mutating func move(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        rows: Int,
        columns: Int
    ) -> Int {
        let clampedRows = max(rows, 1)
        let clampedColumns = max(columns, 1)
        let clampedCount = terminalKeyboardCopyModeClampCount(count)
        clamp(rows: clampedRows, columns: clampedColumns)

        switch direction {
        case .left:
            column = max(0, column - clampedCount)
            return 0
        case .right:
            column = min(clampedColumns - 1, column + clampedCount)
            return 0
        case .up:
            return moveVertically(delta: -clampedCount, rows: clampedRows)
        case .down:
            return moveVertically(delta: clampedCount, rows: clampedRows)
        case .pageUp:
            return moveVertically(delta: -(clampedRows * clampedCount), rows: clampedRows)
        case .pageDown:
            return moveVertically(delta: clampedRows * clampedCount, rows: clampedRows)
        case .home:
            row = 0
            column = 0
            return 0
        case .end:
            row = clampedRows - 1
            column = clampedColumns - 1
            return 0
        case .beginningOfLine:
            column = 0
            return 0
        case .endOfLine:
            column = clampedColumns - 1
            return 0
        }
    }

    /// Moves the cursor after Ghostty has adjusted a visual-selection endpoint.
    ///
    /// Ghostty owns viewport scrolling for `adjust_selection`; this method keeps the visible
    /// cursor model in step with the adjusted endpoint without asking callers to apply the
    /// overflow returned by ``move(_:count:rows:columns:)``.
    ///
    /// - Parameters:
    ///   - direction: The selection endpoint movement that Ghostty applied.
    ///   - count: The repeat count for this movement.
    ///   - rows: The current terminal viewport row count.
    ///   - columns: The current terminal viewport column count.
    public mutating func moveAfterTerminalSelectionAdjustment(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        rows: Int,
        columns: Int
    ) {
        _ = move(direction, count: count, rows: rows, columns: columns)
    }

    /// Shifts the visible cursor row after the viewport scrolls without moving the cursor's text.
    ///
    /// Positive line deltas scroll the terminal viewport downward, so the same text appears on a
    /// smaller visible row. Negative deltas scroll upward, moving the same text toward the bottom.
    ///
    /// - Parameters:
    ///   - lineDelta: The signed viewport scroll delta applied by Ghostty.
    ///   - rows: The current terminal viewport row count.
    ///   - columns: The current terminal viewport column count.
    public mutating func shiftForViewportScroll(lineDelta: Int, rows: Int, columns: Int) {
        row -= lineDelta
        clamp(rows: rows, columns: columns)
    }

    private mutating func moveVertically(delta: Int, rows: Int) -> Int {
        let target = row + delta
        if target < 0 {
            row = 0
            return target
        }
        if target >= rows {
            row = rows - 1
            return target - (rows - 1)
        }
        row = target
        return 0
    }

    private static func clamp(_ value: Int, upperBound: Int) -> Int {
        max(0, min(max(upperBound, 1) - 1, value))
    }
}
