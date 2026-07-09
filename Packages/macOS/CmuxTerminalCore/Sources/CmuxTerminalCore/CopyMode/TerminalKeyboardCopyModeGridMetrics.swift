public import CoreGraphics

/// A snapshot of the terminal grid geometry needed to position the copy-mode cursor.
///
/// The live AppKit surface view builds this value from `ghostty_surface_size`, its
/// resolved cell size, and its view bounds, then hands it to
/// ``TerminalKeyboardCopyModeController`` so every cursor decision is made from one
/// immutable snapshot. The struct also converts a
/// ``TerminalKeyboardCopyModeCursor`` into the view-space rects the host needs for
/// the overlay and synthetic selection.
///
/// ```swift
/// let metrics = TerminalKeyboardCopyModeGridMetrics(
///     rows: 24, columns: 80,
///     cellWidth: 8, cellHeight: 16,
///     xInset: 4, yInset: 2, viewHeight: 386
/// )
/// let rect = metrics.appKitRect(for: TerminalKeyboardCopyModeCursor(row: 3, column: 5))
/// ```
public struct TerminalKeyboardCopyModeGridMetrics: Equatable, Sendable {
    /// The visible viewport row count.
    public let rows: Int
    /// The visible viewport column count.
    public let columns: Int
    /// The resolved cell width in points.
    public let cellWidth: CGFloat
    /// The resolved cell height in points.
    public let cellHeight: CGFloat
    /// The horizontal inset before the grid begins in the host view.
    public let xInset: CGFloat
    /// The vertical inset before the grid begins in the host view.
    public let yInset: CGFloat
    /// The host view height in points.
    public let viewHeight: CGFloat

    /// Creates a grid-metrics snapshot.
    ///
    /// - Parameters:
    ///   - rows: The visible viewport row count.
    ///   - columns: The visible viewport column count.
    ///   - cellWidth: The resolved cell width in points.
    ///   - cellHeight: The resolved cell height in points.
    ///   - xInset: The horizontal inset before the grid begins.
    ///   - yInset: The vertical inset before the grid begins.
    ///   - viewHeight: The host view height in points.
    public init(
        rows: Int,
        columns: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        xInset: CGFloat,
        yInset: CGFloat,
        viewHeight: CGFloat
    ) {
        self.rows = rows
        self.columns = columns
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.xInset = xInset
        self.yInset = yInset
        self.viewHeight = viewHeight
    }

    /// Builds a snapshot from raw surface geometry, computing the visible
    /// viewport row count and the centering insets.
    ///
    /// Mirrors the arithmetic that lived in
    /// `GhosttyNSView.keyboardCopyModeGridMetrics(surface:)`: the visible row
    /// count is clamped to the view height via
    /// ``terminalKeyboardCopyModeVisibleViewportRows(backingRows:viewHeight:cellHeight:)``
    /// and the grid is centered in the host view (`max(0, (view - grid) / 2)`).
    /// The witness still samples `ghostty_surface_size`, resolves the cell size,
    /// and guards positive cell dimensions before calling this.
    ///
    /// - Parameters:
    ///   - backingRows: The surface's backing row count (already clamped ≥ 1).
    ///   - columns: The surface's column count (already clamped ≥ 1).
    ///   - cellWidth: The resolved cell width in points (> 0).
    ///   - cellHeight: The resolved cell height in points (> 0).
    ///   - viewWidth: The host view width in points.
    ///   - viewHeight: The host view height in points.
    /// - Returns: A centered grid-metrics snapshot.
    public static func make(
        backingRows: Int,
        columns: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        viewWidth: CGFloat,
        viewHeight: CGFloat
    ) -> TerminalKeyboardCopyModeGridMetrics {
        let rows = terminalKeyboardCopyModeVisibleViewportRows(
            backingRows: backingRows,
            viewHeight: Double(viewHeight),
            cellHeight: Double(cellHeight)
        )
        let terminalWidth = CGFloat(columns) * cellWidth
        let terminalHeight = CGFloat(rows) * cellHeight
        return TerminalKeyboardCopyModeGridMetrics(
            rows: rows,
            columns: columns,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            xInset: max(0, (viewWidth - terminalWidth) / 2),
            yInset: max(0, (viewHeight - terminalHeight) / 2),
            viewHeight: viewHeight
        )
    }

    /// The top-origin (flipped) rect for a cursor cell, used by synthetic selection.
    ///
    /// - Parameter cursor: The cursor to convert.
    /// - Returns: A rect whose origin is at the top-left of the host view.
    public func topOriginRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
        CGRect(
            x: xInset + (CGFloat(cursor.column) * cellWidth),
            y: yInset + (CGFloat(cursor.row) * cellHeight),
            width: cellWidth,
            height: cellHeight
        )
    }

    /// The AppKit (bottom-origin) rect for a cursor cell, used by the overlay view.
    ///
    /// - Parameter cursor: The cursor to convert.
    /// - Returns: A rect in AppKit coordinates clamped into the host view.
    public func appKitRect(for cursor: TerminalKeyboardCopyModeCursor) -> CGRect {
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
