public import CoreGraphics

// Pure offset/point -> cell -> visible-line math behind command-click word
// path resolution. The caller gathers live terminal state (grid size, the
// visible-text snapshot, view bounds, and cell size) and feeds it here; these
// transforms map a viewport offset or a view-space point onto a cell in the
// captured visible lines and resolve the path token at that cell.

extension TerminalPathResolver {
    /// Resolves the word path at a viewport cell offset.
    ///
    /// Maps `viewportOffsetStart` onto a row/column in the captured
    /// `visibleLines` (accounting for the rows the snapshot is shorter than the
    /// grid), then resolves the path token at that cell.
    ///
    /// - Parameters:
    ///   - viewportOffsetStart: The flat cell offset into the viewport grid.
    ///   - columns: The grid column count (clamped to at least 1 by the caller).
    ///   - rows: The grid row count (clamped to at least 1 by the caller).
    ///   - visibleLines: The captured visible terminal lines, bottom-aligned.
    ///   - cwd: The surface's working directory for relative candidates.
    /// - Returns: The resolution with source ``WordPathResolutionSource/snapshot``, or `nil`.
    public func resolveVisibleWordPath(
        viewportOffsetStart: Int,
        columns: Int,
        rows: Int,
        visibleLines: [String],
        cwd: String
    ) -> WordPathResolution? {
        let rowOffset = max(0, rows - visibleLines.count)
        let rowFromTop = max(0, min(rows - 1, viewportOffsetStart / columns))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(columns - 1, viewportOffsetStart % columns))
        guard let resolution = resolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return WordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }

    /// Resolves the word path at a view-space point.
    ///
    /// Maps `point` onto a row/column in the captured `visibleLines` using the
    /// view bounds, cell size, and the centering insets the grid is drawn with,
    /// then resolves the path token at that cell.
    ///
    /// - Parameters:
    ///   - point: The view-space point (origin bottom-left, AppKit convention).
    ///   - bounds: The view bounds size.
    ///   - cellWidth: The resolved cell width in points (must be > 0).
    ///   - cellHeight: The resolved cell height in points (must be > 0).
    ///   - columns: The grid column count (clamped to at least 1 by the caller).
    ///   - rows: The grid row count (clamped to at least 1 by the caller).
    ///   - visibleLines: The captured visible terminal lines, bottom-aligned.
    ///   - cwd: The surface's working directory for relative candidates.
    /// - Returns: The resolution with source ``WordPathResolutionSource/snapshot``, or `nil`.
    public func resolveVisibleWordPath(
        atPoint point: CGPoint,
        bounds: CGSize,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        columns: Int,
        rows: Int,
        visibleLines: [String],
        cwd: String
    ) -> WordPathResolution? {
        let rowOffset = max(0, rows - visibleLines.count)
        let xInset = max(0, (bounds.width - (CGFloat(columns) * cellWidth)) / 2)
        let yInset = max(0, (bounds.height - (CGFloat(rows) * cellHeight)) / 2)

        let yFromTop = bounds.height - point.y
        let rowFromTop = max(0, min(rows - 1, Int((yFromTop - yInset) / cellHeight)))
        let visibleRow = rowFromTop - rowOffset
        guard visibleRow >= 0, visibleRow < visibleLines.count else { return nil }

        let column = max(0, min(columns - 1, Int((point.x - xInset) / cellWidth)))
        guard let resolution = resolveVisibleLinePath(
            visibleLines[visibleRow],
            column: column,
            cwd: cwd
        ) else {
            return nil
        }

        return WordPathResolution(
            path: resolution.path,
            source: .snapshot,
            rawToken: resolution.rawToken
        )
    }
}
