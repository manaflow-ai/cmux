import CoreGraphics

/// A cell coordinate in the terminal's VIEWPORT space: `(0, 0)` is the top-left
/// visible cell. These are the same coordinates ``GhosttySurfaceView`` derives
/// from a touch via `scrollCell(at:)` and the same coordinates a
/// `GHOSTTY_POINT_VIEWPORT` / `GHOSTTY_POINT_COORD_EXACT` point feeds to
/// `ghostty_surface_read_text`.
struct TerminalGridCell: Equatable, Sendable {
    var col: Int
    var row: Int

    init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}

/// Cell metrics in POINT space (already divided by the screen scale), describing
/// how a viewport cell maps to a rect in the host view's coordinate system. The
/// mapping is the exact inverse of ``TerminalSelectionGeometry/cell(at:geometry:)``
/// (the math `GhosttySurfaceView.scrollCell(at:)` runs): a cell `(col, row)`
/// occupies the half-open box
/// `[origin.x + col·cellWidth, origin.x + (col+1)·cellWidth)` ×
/// `[origin.y + row·cellHeight, origin.y + (row+1)·cellHeight)`.
struct TerminalSelectionCellGeometry: Equatable, Sendable {
    /// Top-left of the FIRST GLYPH in view points: `lastRenderRect.origin` plus
    /// ghostty's `window-padding` inset. Ghostty draws the grid inset from the
    /// surface edge (`col = floor((x − padding.left) / cell_width)`, see
    /// `ghostty/src/renderer/size.zig`), so cell `(0, 0)` is NOT at the
    /// render-rect corner — using the bare corner shifts every rect left by the
    /// padding.
    var origin: CGPoint
    /// TRUE per-cell advance in points (`ghostty_surface_size.cell_width_px /
    /// scale`). NOT `surface_width / columns`: that folds the right-edge padding
    /// remainder into every column, so the highlight drifts ~half a glyph off the
    /// text by mid-line and up to a full cell by the right edge.
    var cellWidth: CGFloat
    /// TRUE per-cell advance in points (`ghostty_surface_size.cell_height_px /
    /// scale`); same reasoning as ``cellWidth`` for the vertical axis.
    var cellHeight: CGFloat
    /// Number of columns in the grid; bounds full-row spans and clamps columns.
    var columns: Int
    /// Number of rows in the grid; clamps rows.
    var rows: Int

    init(origin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat, columns: Int, rows: Int) {
        self.origin = origin
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.columns = columns
        self.rows = rows
    }
}

/// Pure selection math shared by the drag-selection overlay and the local
/// text-extraction read. Deliberately UIKit-free (CoreGraphics only) so the
/// cell↔rect and anchor/focus↔ordered-range logic is unit-testable without a
/// surface, a window, or a simulator.
///
/// The iPad terminal is a thin mirror of the Mac's ghostty surface, so the
/// on-device ghostty selection is never visible (the Mac owns it and re-streams
/// highlighted cells over the render-grid). The drag selection is therefore
/// rendered and tracked entirely from these functions; see
/// ``GhosttySurfaceView/handleSelectionPan(_:)``.
enum TerminalSelectionGeometry {
    /// True when `lhs` is at or before `rhs` in row-major reading order.
    static func precedesOrEqual(_ lhs: TerminalGridCell, _ rhs: TerminalGridCell) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.col <= rhs.col
    }

    /// Clamp a cell into `[0, columns-1] × [0, rows-1]`. A drag can run past the
    /// last column or below the last row (the recognizer keeps reporting points
    /// outside the render rect), so every cell is clamped before it drives a
    /// rect or a text range. `columns`/`rows` of 0 collapse to the origin cell.
    static func clamp(_ cell: TerminalGridCell, columns: Int, rows: Int) -> TerminalGridCell {
        let maxCol = max(columns - 1, 0)
        let maxRow = max(rows - 1, 0)
        return TerminalGridCell(
            col: min(max(cell.col, 0), maxCol),
            row: min(max(cell.row, 0), maxRow)
        )
    }

    /// Order an `anchor` (drag start) and `focus` (current/end) pair into the
    /// inclusive `(start, end)` range in reading order, clamping both to the
    /// grid. `start` is always at or before `end`, so it maps directly to a
    /// ghostty selection's `top_left` / `bottom_right`.
    static func normalizedRange(
        anchor: TerminalGridCell,
        focus: TerminalGridCell,
        columns: Int,
        rows: Int
    ) -> (start: TerminalGridCell, end: TerminalGridCell) {
        let a = clamp(anchor, columns: columns, rows: rows)
        let b = clamp(focus, columns: columns, rows: rows)
        return precedesOrEqual(a, b) ? (a, b) : (b, a)
    }

    /// The highlight rectangles (one per visual row) for the inclusive selection
    /// from `anchor` to `focus`, in the standard terminal selection shape:
    ///
    /// - single row: `start.col … end.col`
    /// - first row:  `start.col … lastColumn`
    /// - middle rows: `0 … lastColumn` (full width)
    /// - last row:   `0 … end.col`
    ///
    /// Rects are in the host view's point space, computed from `geometry`.
    static func selectionRects(
        anchor: TerminalGridCell,
        focus: TerminalGridCell,
        geometry: TerminalSelectionCellGeometry
    ) -> [CGRect] {
        let (start, end) = normalizedRange(
            anchor: anchor,
            focus: focus,
            columns: geometry.columns,
            rows: geometry.rows
        )
        let lastColumn = max(geometry.columns - 1, 0)

        func rowRect(row: Int, fromCol: Int, toCol: Int) -> CGRect {
            let lo = min(fromCol, toCol)
            let hi = max(fromCol, toCol)
            let x = geometry.origin.x + CGFloat(lo) * geometry.cellWidth
            let y = geometry.origin.y + CGFloat(row) * geometry.cellHeight
            let width = CGFloat(hi - lo + 1) * geometry.cellWidth
            return CGRect(x: x, y: y, width: width, height: geometry.cellHeight)
        }

        if start.row == end.row {
            return [rowRect(row: start.row, fromCol: start.col, toCol: end.col)]
        }

        var rects: [CGRect] = []
        rects.append(rowRect(row: start.row, fromCol: start.col, toCol: lastColumn))
        if end.row > start.row + 1 {
            for row in (start.row + 1)...(end.row - 1) {
                rects.append(rowRect(row: row, fromCol: 0, toCol: lastColumn))
            }
        }
        rects.append(rowRect(row: end.row, fromCol: 0, toCol: end.col))
        return rects
    }

    /// The viewport cell containing `point` (host-view point space) — the exact
    /// inverse of ``selectionRects``' per-cell rect: `col = ⌊(x − origin.x) /
    /// cellWidth⌋`, `row = ⌊(y − origin.y) / cellHeight⌋`, each clamped to ≥ 0
    /// (the recognizer can report points left of / above the grid; the upper
    /// bound is applied later by ``normalizedRange`` so a drag can run past the
    /// last column/row). This is the math ``GhosttySurfaceView/scrollCell(at:)``
    /// runs, kept here so the point→cell hit-test and the cell→rect highlight are
    /// derived from ONE definition and cannot drift apart.
    static func cell(
        at point: CGPoint,
        geometry: TerminalSelectionCellGeometry
    ) -> TerminalGridCell {
        let col = max(0, Int((point.x - geometry.origin.x) / geometry.cellWidth))
        let row = max(0, Int((point.y - geometry.origin.y) / geometry.cellHeight))
        return TerminalGridCell(col: col, row: row)
    }
}
