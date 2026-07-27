import Foundation

/// Converts a Ghostty cell dimension from device pixels to AppKit points.
///
/// Ghostty reports cell dimensions in device pixels, while copy-mode overlays
/// are laid out in AppKit points. Prefer the latest cell-size action and fall
/// back to the surface size when that action has not arrived yet.
public func terminalKeyboardCopyModeCellDimensionPoints(
    reportedCellDimensionPixels: Double,
    surfaceCellDimensionPixels: Double,
    backingScaleFactor: Double
) -> Double {
    let scale = backingScaleFactor.isFinite && backingScaleFactor > 0
        ? backingScaleFactor
        : 1
    let pixels = reportedCellDimensionPixels.isFinite && reportedCellDimensionPixels > 0
        ? reportedCellDimensionPixels
        : surfaceCellDimensionPixels
    guard pixels.isFinite, pixels > 0 else { return 0 }
    return pixels / scale
}

/// Resolves the row count that is actually visible in the terminal host view.
///
/// Ghostty can report a backing grid that is taller than the clipped AppKit
/// host view by a small number of rows. Vim-mode cursor movement should use the
/// visible rows so edge scrolling begins when the cursor reaches the visible
/// edge rather than after it moves into clipped backing rows.
///
/// ```swift
/// let rows = terminalKeyboardCopyModeVisibleViewportRows(
///     backingRows: 42,
///     viewHeight: 720,
///     cellHeight: 18
/// )
/// ```
///
/// - Parameters:
///   - backingRows: The row count reported by the terminal surface.
///   - viewHeight: The AppKit host view height in points.
///   - cellHeight: The terminal cell height in points.
/// - Returns: A positive row count constrained to the visible host viewport.
public func terminalKeyboardCopyModeVisibleViewportRows(
    backingRows: Int,
    viewHeight: Double,
    cellHeight: Double
) -> Int {
    let clampedBackingRows = max(backingRows, 1)
    guard viewHeight > 0, cellHeight > 0 else { return clampedBackingRows }

    let fittedRows = max(Int(floor(viewHeight / cellHeight)), 1)
    return min(clampedBackingRows, fittedRows)
}

/// Resolves the initial copy-mode cursor row from Ghostty's IME point.
///
/// Ghostty exposes the live cursor as an IME rectangle rather than as viewport
/// cell coordinates. This helper converts that top-origin Y coordinate into the
/// row used by ``TerminalKeyboardCopyModeCursor`` when keyboard copy mode starts.
///
/// ```swift
/// let row = terminalKeyboardCopyModeInitialViewportRow(
///     rows: 24,
///     imePointY: 240,
///     imeCellHeight: 24
/// )
/// ```
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
/// Ghostty reports the cursor X coordinate at the cell midpoint. This helper
/// converts that coordinate into the zero-based column used by
/// ``TerminalKeyboardCopyModeCursor``.
///
/// ```swift
/// let column = terminalKeyboardCopyModeInitialViewportColumn(
///     columns: 80,
///     imePointX: 235,
///     imeCellWidth: 10,
///     leftPadding: 5
/// )
/// ```
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
