public import Foundation

/// Maps terminal grid cells to the linear character offsets that accessibility
/// clients speak in.
///
/// AX text APIs address content by character range, but a terminal surface keeps
/// no text snapshot to index, so there is no real character stream behind those
/// ranges. A row-major index over the visible grid gives assistive tools a
/// stable, invertible address for the caret, which is what a magnifier needs to
/// follow the insertion point while the user types.
///
/// ```swift
/// let grid = TerminalCaretGrid(rows: 10, columns: 40)!
/// grid.index(row: 3, column: 7)   // 127
/// grid.cell(forIndex: 127)        // (row: 3, column: 7)
/// ```
public struct TerminalCaretGrid: Equatable, Sendable {
    /// Number of visible rows in the grid.
    public let rows: Int

    /// Number of visible columns in the grid.
    public let columns: Int

    /// Creates a grid, or returns `nil` when either dimension has no cells.
    ///
    /// - Parameters:
    ///   - rows: Visible row count. Must be positive.
    ///   - columns: Visible column count. Must be positive.
    public init?(rows: Int, columns: Int) {
        guard rows > 0, columns > 0 else { return nil }
        self.rows = rows
        self.columns = columns
    }

    /// Total addressable offsets, one per visible cell.
    public var characterCount: Int { rows * columns }

    /// Row-major offset for a cell, clamped into the visible grid.
    ///
    /// - Parameters:
    ///   - row: Zero-based viewport row. Values outside the grid are clamped.
    ///   - column: Zero-based viewport column. Values outside the grid are clamped.
    /// - Returns: An offset in `0..<characterCount`.
    public func index(row: Int, column: Int) -> Int {
        let clampedRow = min(max(row, 0), rows - 1)
        let clampedColumn = min(max(column, 0), columns - 1)
        return (clampedRow * columns) + clampedColumn
    }

    /// Inverse of ``index(row:column:)``, clamped into the visible grid.
    ///
    /// - Parameter index: An offset, clamped to `0..<characterCount`.
    /// - Returns: The cell that offset addresses.
    public func cell(forIndex index: Int) -> (row: Int, column: Int) {
        let clamped = min(max(index, 0), characterCount - 1)
        return (clamped / columns, clamped % columns)
    }

    /// Single-row cell span covering `range`.
    ///
    /// Bounds queries are answered one row at a time: a caret query has zero
    /// length, and a multi-row selection has no soft-wrap identity here, so the
    /// span stops at the end of the starting row.
    ///
    /// - Parameter range: Offsets to cover. Zero length is treated as one cell.
    /// - Returns: The starting cell and how many cells to span from it.
    public func span(for range: NSRange) -> (row: Int, column: Int, widthCells: Int) {
        let start = cell(forIndex: range.location)
        let remainingInRow = columns - start.column
        return (start.row, start.column, min(max(range.length, 1), remainingInRow))
    }

    /// Offsets covering one visible row.
    ///
    /// - Parameter line: Zero-based viewport row.
    /// - Returns: The row's offsets, or an empty range when `line` is outside
    ///   the grid.
    public func range(forLine line: Int) -> NSRange {
        guard line >= 0, line < rows else { return NSRange(location: 0, length: 0) }
        return NSRange(location: line * columns, length: columns)
    }
}
