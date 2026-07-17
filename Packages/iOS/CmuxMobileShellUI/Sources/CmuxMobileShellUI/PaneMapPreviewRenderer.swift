import CMUXMobileCore

/// Assembles compact plain-text terminal rows for pane-map previews.
struct PaneMapPreviewRenderer {
    /// Renders the content-bearing tail of a render-grid frame as fixed-width text.
    ///
    /// Spans are applied in their source order, so a later overlapping span wins.
    /// Text that reaches beyond the grid's final column is truncated.
    ///
    /// - Parameters:
    ///   - frame: The render-grid snapshot to assemble.
    ///   - maximumRows: The maximum number of grid rows to return.
    /// - Returns: Fixed-width strings ordered from the first included row to the last.
    static func rows(
        in frame: MobileTerminalRenderGridFrame,
        maximumRows: Int = 20
    ) -> [String] {
        rows(
            columns: frame.columns,
            rowCount: frame.rows,
            rowSpans: frame.rowSpans,
            cursorRow: frame.cursor?.row,
            maximumRows: maximumRows
        )
    }

    /// Pure assembly seam used by focused unit tests and the frame renderer.
    ///
    /// The window ends at the last row that has content (or the cursor row,
    /// whichever is lower), not at the grid's bottom: a cleared tall grid keeps
    /// its content at the top, and a bottom-anchored window would show only
    /// blank rows for it (this is exactly what a phone-attached surface's
    /// phone-sized grid looks like right after `clear`).
    static func rows(
        columns: Int,
        rowCount: Int,
        rowSpans: [MobileTerminalRenderGridFrame.RowSpan],
        cursorRow: Int? = nil,
        maximumRows: Int = 20
    ) -> [String] {
        guard columns > 0, rowCount > 0, maximumRows > 0 else { return [] }

        let lastSpanRow = rowSpans.map(\.row).max()
        let lastContentRow = max(lastSpanRow ?? 0, cursorRow ?? 0)
        let endRow = min(rowCount, max(lastContentRow + 1, min(rowCount, maximumRows)))
        let firstRow = max(0, endRow - maximumRows)
        return (firstRow..<endRow).map { row in
            var characters = Array(repeating: Character(" "), count: columns)
            for span in rowSpans where span.row == row {
                guard span.column >= 0, span.column < columns else { continue }
                for (offset, character) in span.text.enumerated() {
                    let column = span.column + offset
                    guard column < columns else { break }
                    characters[column] = character
                }
            }
            return String(characters)
        }
    }
}
