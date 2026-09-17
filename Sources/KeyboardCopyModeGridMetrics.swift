import AppKit

struct KeyboardCopyModeGridMetrics {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let xInset: CGFloat
    let yInset: CGFloat
    let viewHeight: CGFloat

    func topOriginRect(for cell: KeyboardCopyModeResolvedCell) -> CGRect {
        CGRect(
            x: xInset + (CGFloat(cell.cursor.column) * cellWidth),
            y: yInset + (CGFloat(cell.cursor.row) * cellHeight),
            width: cellWidth * CGFloat(max(cell.widthCells, 1)),
            height: cellHeight
        )
    }

    func appKitRect(for cell: KeyboardCopyModeResolvedCell) -> CGRect {
        let topOrigin = topOriginRect(for: cell)
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
