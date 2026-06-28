import CoreGraphics

/// A cell coordinate in the terminal's VIEWPORT space: `(0, 0)` is the top-left
/// visible cell. These are the same coordinates ``GhosttySurfaceView`` derives
/// from a touch via `scrollCell(at:)` and the same coordinates a
/// `GHOSTTY_POINT_VIEWPORT` / `GHOSTTY_POINT_COORD_EXACT` point feeds to
/// `ghostty_surface_read_text`.
struct TerminalGridCell: Equatable, Sendable {
    /// Zero-based column, counting from the left edge of the viewport.
    var col: Int
    /// Zero-based row, counting from the top visible row of the viewport.
    var row: Int

    /// Creates a cell at the given viewport `(col, row)`.
    init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}

/// Cell metrics in POINT space (already divided by the screen scale), describing
/// how a viewport cell maps to a rect in the host view's coordinate system. The
/// mapping is the exact inverse of ``TerminalSelectionCellGeometry/cell(at:)``
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

    /// Creates a cell-geometry snapshot from ghostty's measured render metrics.
    init(origin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat, columns: Int, rows: Int) {
        self.origin = origin
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.columns = columns
        self.rows = rows
    }
}

extension TerminalGridCell {
    /// True when `self` is at or before `other` in row-major reading order.
    func precedes(orEqualTo other: TerminalGridCell) -> Bool {
        row != other.row ? row < other.row : col <= other.col
    }

    /// This cell clamped into `[0, columns-1] × [0, rows-1]`. A drag can run past
    /// the last column or below the last row (the recognizer keeps reporting
    /// points outside the render rect), so every cell is clamped before it drives
    /// a rect or a text range. `columns`/`rows` of 0 collapse to the origin cell.
    func clamped(toColumns columns: Int, rows: Int) -> TerminalGridCell {
        let maxCol = max(columns - 1, 0)
        let maxRow = max(rows - 1, 0)
        return TerminalGridCell(
            col: min(max(col, 0), maxCol),
            row: min(max(row, 0), maxRow)
        )
    }
}

/// Pure selection math hung off the cell geometry that owns the metrics, shared
/// by the drag-selection overlay and the local text-extraction read. Deliberately
/// UIKit-free (CoreGraphics only) so the cell↔rect and anchor/focus↔ordered-range
/// logic is unit-testable without a surface, a window, or a simulator.
///
/// The iPad terminal is a thin mirror of the Mac's ghostty surface, so the
/// on-device ghostty selection is never visible (the Mac owns it and re-streams
/// highlighted cells over the render-grid). The drag selection is therefore
/// rendered and tracked entirely from these methods; see
/// ``GhosttySurfaceView/handleSelectionPan(_:)``.
extension TerminalSelectionCellGeometry {
    /// Order an `anchor` (drag start) and `focus` (current/end) pair into the
    /// inclusive `(start, end)` range in reading order, clamping both to the grid.
    /// `start` is always at or before `end`, so it maps directly to a ghostty
    /// selection's `top_left` / `bottom_right`.
    func normalizedRange(
        anchor: TerminalGridCell,
        focus: TerminalGridCell
    ) -> (start: TerminalGridCell, end: TerminalGridCell) {
        let a = anchor.clamped(toColumns: columns, rows: rows)
        let b = focus.clamped(toColumns: columns, rows: rows)
        return a.precedes(orEqualTo: b) ? (a, b) : (b, a)
    }

    /// The highlight rectangles (one per visual row) for the inclusive selection
    /// from `anchor` to `focus`, in the standard terminal selection shape:
    ///
    /// - single row: `start.col … end.col`
    /// - first row:  `start.col … lastColumn`
    /// - middle rows: `0 … lastColumn` (full width)
    /// - last row:   `0 … end.col`
    ///
    /// Rects are in the host view's point space, computed from this geometry.
    func selectionRects(
        anchor: TerminalGridCell,
        focus: TerminalGridCell
    ) -> [CGRect] {
        let (start, end) = normalizedRange(anchor: anchor, focus: focus)
        let lastColumn = max(columns - 1, 0)

        func rowRect(row: Int, fromCol: Int, toCol: Int) -> CGRect {
            let lo = min(fromCol, toCol)
            let hi = max(fromCol, toCol)
            let x = origin.x + CGFloat(lo) * cellWidth
            let y = origin.y + CGFloat(row) * cellHeight
            let width = CGFloat(hi - lo + 1) * cellWidth
            return CGRect(x: x, y: y, width: width, height: cellHeight)
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
    /// inverse of ``selectionRects(anchor:focus:)``' per-cell rect: `col = ⌊(x −
    /// origin.x) / cellWidth⌋`, `row = ⌊(y − origin.y) / cellHeight⌋`, each clamped
    /// to ≥ 0 (the recognizer can report points left of / above the grid; the upper
    /// bound is applied later by ``normalizedRange(anchor:focus:)`` so a drag can
    /// run past the last column/row). This is the math
    /// ``GhosttySurfaceView/scrollCell(at:)`` runs, kept here so the point→cell
    /// hit-test and the cell→rect highlight are derived from ONE definition and
    /// cannot drift apart.
    func cell(at point: CGPoint) -> TerminalGridCell {
        let col = max(0, Int((point.x - origin.x) / cellWidth))
        let row = max(0, Int((point.y - origin.y) / cellHeight))
        return TerminalGridCell(col: col, row: row)
    }
}
