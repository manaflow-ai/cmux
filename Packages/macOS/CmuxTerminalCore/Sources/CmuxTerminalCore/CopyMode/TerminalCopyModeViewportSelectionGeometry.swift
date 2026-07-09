public import CoreGraphics

/// The synthetic-drag start and end points used to copy a run of viewport lines.
///
/// When the scrollback/selection copy command needs to lift a contiguous block of
/// viewport lines onto the clipboard, the live AppKit surface view synthesizes a
/// Ghostty mouse drag from the first line to the last. This value computes the two
/// view-space points that drag uses, given an immutable
/// ``TerminalKeyboardCopyModeGridMetrics`` snapshot, the starting row, the run
/// length, and the host view bounds. The host keeps every `ghostty_surface_*` C
/// call and only sources the two coordinates from here, so the pixel math is unit
/// testable and lives off the AppKit view.
///
/// The points are clamped into the host view: Y values into `[0, height - 1]` at
/// each row's cell midpoint, X values to the grid's left inset and right edge,
/// bounded by `width - 1`.
///
/// ```swift
/// let geometry = TerminalCopyModeViewportSelectionGeometry(
///     metrics: metrics,
///     startRow: 3,
///     lineCount: 5,
///     boundsSize: view.bounds.size
/// )
/// ghostty_surface_mouse_pos(surface, Double(geometry.startPoint.x), Double(geometry.startPoint.y), mods)
/// ```
public struct TerminalCopyModeViewportSelectionGeometry: Equatable, Sendable {
    /// The view-space point where the synthetic drag presses down (first line).
    public let startPoint: CGPoint
    /// The view-space point where the synthetic drag releases (last line).
    public let endPoint: CGPoint

    /// Creates a geometry from explicit drag endpoints.
    ///
    /// - Parameters:
    ///   - startPoint: The drag-press point.
    ///   - endPoint: The drag-release point.
    public init(startPoint: CGPoint, endPoint: CGPoint) {
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    /// Computes the synthetic-drag endpoints for a run of viewport lines.
    ///
    /// - Parameters:
    ///   - metrics: The immutable grid-geometry snapshot.
    ///   - startRow: The first viewport row to include (clamped into the grid).
    ///   - lineCount: The number of lines to select (clamped via
    ///     ``terminalKeyboardCopyModeClampCount(_:)``).
    ///   - boundsSize: The host view bounds used to clamp both points.
    public init(
        metrics: TerminalKeyboardCopyModeGridMetrics,
        startRow: Int,
        lineCount: Int,
        boundsSize: CGSize
    ) {
        let clampedCount = terminalKeyboardCopyModeClampCount(lineCount)
        let rows = metrics.rows
        let targetRow = max(0, min(rows - 1, startRow))
        let endRow = min(rows - 1, targetRow + clampedCount - 1)

        let yMax = max(boundsSize.height - 1, 0)

        let startRawY = metrics.topOriginRect(
            for: TerminalKeyboardCopyModeCursor(row: targetRow, column: 0)
        ).midY
        let endRawY = metrics.topOriginRect(
            for: TerminalKeyboardCopyModeCursor(row: endRow, column: max(metrics.columns - 1, 0))
        ).midY
        let startY = max(0, min(startRawY, yMax))
        let endY = max(0, min(endRawY, yMax))
        let xMax = max(boundsSize.width - 1, 0)
        let startX = min(metrics.xInset + 0.5, xMax)
        let endX = min(metrics.xInset + (CGFloat(metrics.columns) * metrics.cellWidth) - 0.5, xMax)

        self.startPoint = CGPoint(x: startX, y: startY)
        self.endPoint = CGPoint(x: endX, y: endY)
    }
}
