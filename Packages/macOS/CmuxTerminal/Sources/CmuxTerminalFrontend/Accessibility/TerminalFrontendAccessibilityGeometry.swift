internal import Foundation

/// Converts top-origin terminal rows to AppKit's unflipped local coordinates.
enum TerminalFrontendAccessibilityGeometry {
    static func unflippedCellY(
        boundsMinimumY: Double,
        boundsHeight: Double,
        yInset: Double,
        cellHeight: Double,
        viewportRow: Int
    ) -> Double {
        boundsMinimumY + boundsHeight - yInset - (Double(viewportRow + 1) * cellHeight)
    }

    static func unflippedViewportRow(
        localY: Double,
        boundsMinimumY: Double,
        boundsHeight: Double,
        yInset: Double,
        cellHeight: Double
    ) -> Int {
        Int(floor(
            (boundsMinimumY + boundsHeight - localY - yInset) / cellHeight
        ))
    }
}
