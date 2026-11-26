#if os(iOS) && DEBUG
import CoreGraphics

/// DEBUG probe for the highlight demo (`highlight-find`, `highlight-select`;
/// TerminalHighlightScrollUITests). Leo, 2026-11-24: "sometimes the highlights in
/// terminal just float and dont move when i scroll?" It reads the highlights as drawn
/// (their rects in the full-screen app's host) back to the cells under them and the text
/// those cells show now, so a highlight left behind over other text counts as off.
extension TerminalViewController {
    /// The viewport cell under the first column of `rect` (a highlight's row).
    private func probeCells(_ rect: CGRect) -> (TerminalCellPoint, TerminalCellPoint)? {
        let width = surface.cellSize.width
        guard width > 0, let first = tuiSelection.cellAt(CGPoint(x: rect.minX + width / 2, y: rect.midY)),
              let last = tuiSelection.cellAt(CGPoint(x: rect.maxX - width / 2, y: rect.midY)) else { return nil }
        return (first, last)
    }

    /// `on=N off=N missed=N`: find highlights on a match of `query` the screen shows now,
    /// highlights over other text, and matches on the screen with no highlight.
    func findHighlightProbe(query: String) -> String {
        let columns = max(1, surface.grid.columns)
        let rows = (0..<max(0, surface.grid.rows)).map { tuiSelection.rowText($0) ?? "" }
        let shown = TerminalFindResults(rows: rows, wraps: Array(repeating: false, count: rows.count), firstRow: 0,
                                        columns: columns, query: query)
        let wanted = Set(shown.matches.compactMap { $0.segments.first.map { TerminalCellPoint(row: $0.row, column: $0.start) } })
        var drawn = Set<TerminalCellPoint>()
        for rect in finder.drawnRects {
            if let (first, _) = probeCells(rect) { drawn.insert(first) }
        }
        return "on=\(drawn.intersection(wanted).count) off=\(drawn.subtracting(wanted).count) missed=\(wanted.subtracting(drawn).count)"
    }

    /// Selects `row`'s cells `columns` in the full-screen app, as a long press there does,
    /// and returns their text.
    func selectTUIForProbe(row: Int, columns: ClosedRange<Int>) -> String? {
        let selection = TerminalTextSelection(anchor: TerminalCellPoint(row: row, column: columns.lowerBound),
                                              head: TerminalCellPoint(row: row, column: columns.upperBound))
        tuiSelection.show(selection, handles: true)
        return tuiSelection.text(selection.start, selection.end)
    }

    /// `sel=on`, `sel=off` (the highlight is over other text than `text`) or `sel=none`,
    /// with the rows it is drawn on.
    func selectionHighlightProbe(text: String) -> String {
        let rects = tuiSelection.drawnRects
        guard let rect = rects.first, let (first, last) = probeCells(rect) else { return "sel=none" }
        let under = tuiSelection.text(first, last) ?? ""
        return "sel=\(under == text ? "on" : "off") row=\(first.row) under=\(under.replacingOccurrences(of: " ", with: "_"))"
    }
}
#endif
