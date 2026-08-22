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
