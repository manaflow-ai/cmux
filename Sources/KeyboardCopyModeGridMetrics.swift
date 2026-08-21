import AppKit

struct KeyboardCopyModeGridMetrics {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let xInset: CGFloat
    let yInset: CGFloat
    let viewHeight: CGFloat

    func topOriginRect(for cell: KeyboardCopyModeResolvedCell) -> CGRect {
        topOriginRect(row: cell.cursor.row, column: cell.cursor.column, widthCells: cell.widthCells)
    }

    func topOriginRect(row: Int, column: Int, widthCells: Int) -> CGRect {
        CGRect(
            x: xInset + (CGFloat(column) * cellWidth),
            y: yInset + (CGFloat(row) * cellHeight),
            width: cellWidth * CGFloat(max(widthCells, 1)),
            height: cellHeight
        )
    }

    func appKitRect(for cell: KeyboardCopyModeResolvedCell) -> CGRect {
        appKitRect(row: cell.cursor.row, column: cell.cursor.column, widthCells: cell.widthCells)
    }

    func appKitRect(row: Int, column: Int, widthCells: Int) -> CGRect {
        let topOrigin = topOriginRect(row: row, column: column, widthCells: widthCells)
        let rawY = viewHeight - topOrigin.maxY
        let maxY = max(viewHeight - topOrigin.height, 0)
        return CGRect(
            x: topOrigin.minX,
            y: min(max(rawY, 0), maxY),
            width: topOrigin.width,
            height: topOrigin.height
        )
    }
}

/// Maps terminal grid cells to the linear character offsets that accessibility
/// clients speak in.
///
/// AX text APIs address content by character range, but this layer keeps no
/// terminal text snapshot, so there is no real character stream to index. A
/// row-major index over the visible grid gives assistive tools a stable,
/// invertible address for the caret, which is what Zoom needs to follow the
/// insertion point while the user types.
struct TerminalCaretGrid: Equatable {
    let rows: Int
    let columns: Int

    init?(rows: Int, columns: Int) {
        guard rows > 0, columns > 0 else { return nil }
        self.rows = rows
        self.columns = columns
    }

    var characterCount: Int { rows * columns }

    /// Row-major offset for a cell, clamped into the visible grid.
    func index(row: Int, column: Int) -> Int {
        let clampedRow = min(max(row, 0), rows - 1)
        let clampedColumn = min(max(column, 0), columns - 1)
        return (clampedRow * columns) + clampedColumn
    }

    /// Inverse of ``index(row:column:)``, clamped into the visible grid.
    func cell(forIndex index: Int) -> (row: Int, column: Int) {
        let clamped = min(max(index, 0), characterCount - 1)
        return (clamped / columns, clamped % columns)
    }

    /// Single-row cell span covering `range`.
    ///
    /// Bounds queries are answered one row at a time: a caret query has zero
    /// length, and a multi-row selection has no soft-wrap identity in this
    /// layer, so the span stops at the end of the starting row.
    func span(for range: NSRange) -> (row: Int, column: Int, widthCells: Int) {
        let start = cell(forIndex: range.location)
        let remainingInRow = columns - start.column
        return (start.row, start.column, min(max(range.length, 1), remainingInRow))
    }

    /// Offsets covering one visible row, or an empty range when out of bounds.
    func range(forLine line: Int) -> NSRange {
        guard line >= 0, line < rows else { return NSRange(location: 0, length: 0) }
        return NSRange(location: line * columns, length: columns)
    }
}
