import CMUXMobileCore

/// Assembles compact plain-text terminal rows for pane-map previews.
struct PaneMapPreviewRenderer {
    /// Renders the last visible rows of a render-grid frame as fixed-width text.
    ///
    /// Spans are applied in their source order, so a later overlapping span wins.
    /// Text that reaches beyond the grid's final column is truncated.
    ///
    /// - Parameters:
    ///   - frame: The render-grid snapshot to assemble.
    ///   - maximumRows: The maximum number of trailing grid rows to return.
    /// - Returns: Fixed-width strings ordered from the first included row to the last.
    static func rows(
        in frame: MobileTerminalRenderGridFrame,
        maximumRows: Int = 20
    ) -> [String] {
        rows(
            columns: frame.columns,
            rowCount: frame.rows,
            rowSpans: frame.rowSpans,
            maximumRows: maximumRows
        )
    }

    /// Pure assembly seam used by focused unit tests and the frame renderer.
    static func rows(
        columns: Int,
        rowCount: Int,
        rowSpans: [MobileTerminalRenderGridFrame.RowSpan],
        maximumRows: Int = 20
    ) -> [String] {
        guard columns > 0, rowCount > 0, maximumRows > 0 else { return [] }

        let firstRow = max(0, rowCount - maximumRows)
        return (firstRow..<rowCount).map { row in
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
