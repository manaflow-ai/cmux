/// A viewport-relative cursor used while terminal keyboard copy mode is active.
///
/// `TerminalKeyboardCopyModeCursor` is the pure state model behind the visible
/// copy-mode overlay. Hosts move it with ``move(_:count:rows:columns:)``, clamp it
/// with ``clamp(rows:columns:)`` when the grid changes, and shift it with
/// ``shiftForViewportScroll(lineDelta:rows:columns:)`` when the viewport scrolls.
///
/// ```swift
/// var cursor = TerminalKeyboardCopyModeCursor(row: 8, column: 4)
/// let overflow = cursor.move(.down, count: 2, rows: 10, columns: 40)
/// cursor.shiftForViewportScroll(lineDelta: overflow, rows: 10, columns: 40)
/// ```
public struct TerminalKeyboardCopyModeCursor: Equatable, Sendable {
    /// The zero-based viewport row occupied by the cursor.
    ///
    /// The value is expected to be valid after ``clamp(rows:columns:)`` or
    /// ``clamped(rows:columns:)`` has been applied for the current grid.
    public var row: Int

    /// The zero-based viewport column occupied by the cursor.
    ///
    /// The value is expected to be valid after ``clamp(rows:columns:)`` or
    /// ``clamped(rows:columns:)`` has been applied for the current grid.
    public var column: Int

    /// Creates a cursor at a viewport cell.
    ///
    /// The initializer stores the supplied values as-is. Call
    /// ``clamp(rows:columns:)`` if the values may be outside the active grid.
    ///
    /// ```swift
    /// let cursor = TerminalKeyboardCopyModeCursor(row: 0, column: 0)
    /// ```
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
    /// This nonmutating counterpart to ``clamp(rows:columns:)`` is useful when
    /// callers need a safe value without changing the original cursor.
    ///
    /// ```swift
    /// let clamped = TerminalKeyboardCopyModeCursor(row: 40, column: 2)
    ///     .clamped(rows: 24, columns: 80)
    /// ```
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
    /// Use this after terminal resize events so later
    /// ``move(_:count:rows:columns:)`` or visual-selection anchoring starts from
    /// a valid viewport cell.
    ///
    /// ```swift
    /// var cursor = TerminalKeyboardCopyModeCursor(row: 40, column: 90)
    /// cursor.clamp(rows: 24, columns: 80)
    /// ```
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
    /// Horizontal moves stay inside the grid. Vertical moves clamp to the top or
    /// bottom edge and return the signed overflow line count so the host can
    /// scroll the viewport while the cursor remains visible.
    ///
    /// ```swift
    /// var cursor = TerminalKeyboardCopyModeCursor(row: 23, column: 4)
    /// let scrollDelta = cursor.move(.down, count: 3, rows: 24, columns: 80)
    /// cursor.shiftForViewportScroll(lineDelta: scrollDelta, rows: 24, columns: 80)
    /// ```
    ///
    /// - Parameters:
    ///   - direction: The ``TerminalKeyboardCopyModeSelectionMove`` to apply.
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
    /// ```swift
    /// var cursor = TerminalKeyboardCopyModeCursor(row: 2, column: 1)
    /// cursor.moveAfterTerminalSelectionAdjustment(.right, count: 1, rows: 24, columns: 80)
    /// ```
    ///
    /// - Parameters:
    ///   - direction: The ``TerminalKeyboardCopyModeSelectionMove`` that Ghostty applied.
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
    /// ```swift
    /// var cursor = TerminalKeyboardCopyModeCursor(row: 10, column: 4)
    /// cursor.shiftForViewportScroll(lineDelta: 3, rows: 24, columns: 80)
    /// // cursor.row == 7
    /// ```
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
