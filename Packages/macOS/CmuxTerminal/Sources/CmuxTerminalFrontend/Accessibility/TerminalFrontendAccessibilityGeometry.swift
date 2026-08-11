internal import Foundation

/// Converts a top-origin terminal row to AppKit's unflipped local Y coordinate.
func terminalFrontendUnflippedCellY(
    boundsMinimumY: Double,
    boundsHeight: Double,
    yInset: Double,
    cellHeight: Double,
    viewportRow: Int
) -> Double {
    boundsMinimumY + boundsHeight - yInset - (Double(viewportRow + 1) * cellHeight)
}

/// Converts an AppKit local Y coordinate to a top-origin terminal row.
func terminalFrontendUnflippedViewportRow(
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
