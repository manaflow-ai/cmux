import AppKit
import CmuxTerminalCore
import GhosttyKit

struct KeyboardCopyModeGridMetrics {
    let rows: Int
    let columns: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let xInset: CGFloat
    let yInset: CGFloat
    let viewHeight: CGFloat

    func topOriginRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
        CGRect(
            x: xInset + (CGFloat(cursor.column) * cellWidth),
            y: yInset + (CGFloat(cursor.row) * cellHeight),
            width: cellWidth,
            height: cellHeight
        )
    }

    func appKitRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
        let topOrigin = topOriginRect(for: cursor)
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

extension GhosttyNSView {
    func keyboardCopyModeGridMetrics(surface: ghostty_surface_t) -> KeyboardCopyModeGridMetrics? {
        let size = ghostty_surface_size(surface)
        let backingRows = max(Int(size.rows), 1)
        let columns = max(Int(size.columns), 1)
        let backingScaleFactor = max(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1, 1)
        let resolvedCellWidth = cellSize.width > 0
            ? cellSize.width
            : CGFloat(size.cell_width_px) / backingScaleFactor
        let resolvedCellHeight = cellSize.height > 0
            ? cellSize.height
            : CGFloat(size.cell_height_px) / backingScaleFactor
        guard resolvedCellWidth > 0, resolvedCellHeight > 0 else { return nil }

        let rows = terminalKeyboardCopyModeVisibleViewportRows(
            backingRows: backingRows,
            viewHeight: Double(bounds.height),
            cellHeight: Double(resolvedCellHeight)
        )
        let terminalWidth = CGFloat(columns) * resolvedCellWidth
        let terminalHeight = CGFloat(rows) * resolvedCellHeight
        return KeyboardCopyModeGridMetrics(
            rows: rows,
            columns: columns,
            cellWidth: resolvedCellWidth,
            cellHeight: resolvedCellHeight,
            xInset: max(0, (bounds.width - terminalWidth) / 2),
            yInset: max(0, (bounds.height - terminalHeight) / 2),
            viewHeight: bounds.height
        )
    }
}
