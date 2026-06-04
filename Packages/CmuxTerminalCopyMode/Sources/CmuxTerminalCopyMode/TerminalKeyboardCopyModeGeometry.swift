import Foundation

/// Resolves the initial copy-mode cursor row from Ghostty's IME point.
///
/// - Parameters:
///   - rows: The current terminal viewport row count.
///   - imePointY: Ghostty's top-origin IME Y coordinate.
///   - imeCellHeight: The current terminal cell height.
///   - topPadding: Vertical inset before the terminal grid begins.
/// - Returns: A zero-based row clamped into the viewport.
public func terminalKeyboardCopyModeInitialViewportRow(
    rows: Int,
    imePointY: Double,
    imeCellHeight: Double,
    topPadding: Double = 0
) -> Int {
    let clampedRows = max(rows, 1)
    guard imeCellHeight > 0 else { return clampedRows - 1 }

    let estimatedRow = Int(floor(((imePointY - topPadding) / imeCellHeight) - 1))
    return max(0, min(clampedRows - 1, estimatedRow))
}

/// Resolves the initial copy-mode cursor column from Ghostty's IME point.
///
/// - Parameters:
///   - columns: The current terminal viewport column count.
///   - imePointX: Ghostty's IME X coordinate at the cursor cell midpoint.
///   - imeCellWidth: The current terminal cell width.
///   - leftPadding: Horizontal inset before the terminal grid begins.
/// - Returns: A zero-based column clamped into the viewport.
public func terminalKeyboardCopyModeInitialViewportColumn(
    columns: Int,
    imePointX: Double,
    imeCellWidth: Double,
    leftPadding: Double = 0
) -> Int {
    let clampedColumns = max(columns, 1)
    guard imeCellWidth > 0 else { return 0 }

    let estimatedColumn = Int(floor((imePointX - leftPadding) / imeCellWidth))
    return max(0, min(clampedColumns - 1, estimatedColumn))
}

/// Chooses a nonzero horizontal drag range within a visible cursor cell.
///
/// - Parameters:
///   - rectMinX: The cell's left edge in view coordinates.
///   - rectMaxX: The cell's right edge in view coordinates.
///   - boundsWidth: The containing view width.
/// - Returns: A start/end X pair for synthetic selection, or `nil` when the view is too narrow.
public func terminalKeyboardCopyModeCursorSelectionXRange(
    rectMinX: Double,
    rectMaxX: Double,
    boundsWidth: Double
) -> (startX: Double, endX: Double)? {
    let maxX = boundsWidth - 1
    guard maxX > 0 else { return nil }

    let visibleMinX = min(max(rectMinX, 0), maxX)
    let visibleMaxX = min(max(rectMaxX, 0), maxX)
    let startX = min(max(visibleMinX + 0.5, 0), maxX)
    let endX = min(max(visibleMaxX - 0.5, 0), maxX)
    if endX > startX {
        return (startX, endX)
    }

    let midpointX = min(max((visibleMinX + visibleMaxX) / 2, 0), maxX)
    if midpointX < maxX {
        return (midpointX, min(midpointX + 1, maxX))
    }
    let fallbackEndX = max(midpointX - 1, 0)
    guard fallbackEndX < midpointX else { return nil }
    return (midpointX, fallbackEndX)
}
