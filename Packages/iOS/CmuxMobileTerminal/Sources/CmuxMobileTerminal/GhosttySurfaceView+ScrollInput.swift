import CMUXMobileCore
import UIKit

extension GhosttySurfaceView {
    func enqueueScrollMechanicsDelta(_ deltaY: CGFloat, touchPoint: CGPoint) {
        guard deltaY != 0 else { return }
        guard cellPixelSize.height > 0 else {
            pendingUnmeasuredScrollDeltaY += deltaY
            pendingUnmeasuredScrollTouchPoint = touchPoint
            return
        }
        let cellHeightPoints = cellPixelSize.height / max(preferredScreenScale, 1)
        let primaryDivisor = Double(cellHeightPoints)
        let primaryRows = -Double(deltaY) / primaryDivisor
        let alternateScreenLines = -Double(deltaY) / (primaryDivisor * 3)
        if scrollInputAccumulator.wouldReverse(
            primaryRows: primaryRows,
            alternateScreenLines: alternateScreenLines
        ) {
            flushPendingScrollIfNeeded()
        }
        scrollInputAccumulator.accumulate(
            primaryRows: primaryRows,
            alternateScreenLines: alternateScreenLines
        )
        pendingScrollCell = scrollCell(at: touchPoint)
    }

    func resetPendingScrollInput() {
        scrollInputAccumulator.reset()
        pendingUnmeasuredScrollDeltaY = 0
        pendingUnmeasuredScrollTouchPoint = nil
    }

    func scrollCell(at point: CGPoint) -> (col: Int, row: Int) {
        let scale = max(preferredScreenScale, 1)
        let cellWidth = max(cellPixelSize.width / scale, 1)
        let cellHeight = max(cellPixelSize.height / scale, 1)
        let col = max(0, Int((point.x - lastRenderRect.minX) / cellWidth))
        let row = max(0, Int((point.y - lastRenderRect.minY) / cellHeight))
        return (col, row)
    }

    func flushPendingScrollIfNeeded() {
        let cell = pendingScrollCell
        guard let run = scrollInputAccumulator.drain(col: cell.col, row: cell.row) else { return }
        delegate?.ghosttySurfaceView(self, didScroll: run)
    }
}
