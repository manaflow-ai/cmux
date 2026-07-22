/// A terminal-grid snapshot prepared for a compact pane-map renderer.
public struct MobileTerminalPaneMapPreview: Equatable, Sendable {
    /// One terminal column after overlapping spans and wide glyphs are resolved.
    public struct Cell: Equatable, Sendable {
        /// The grapheme painted at this column, a space for an empty cell, or an
        /// empty string when this column continues a wide grapheme.
        public let text: String
        /// The render-grid style identifier applied to this cell.
        public let styleID: Int
        /// The number of terminal columns occupied by a glyph-start cell.
        /// Continuation cells use zero.
        public let columnSpan: Int

        fileprivate init(text: String, styleID: Int, columnSpan: Int) {
            self.text = text
            self.styleID = styleID
            self.columnSpan = columnSpan
        }
    }

    public let surfaceID: String
    public let columns: Int
    public let sourceRows: Int
    public let firstSourceRow: Int
    public let styles: [MobileTerminalRenderGridFrame.Style]
    public let stylesByID: [Int: MobileTerminalRenderGridFrame.Style]
    public let rows: [[Cell]]

    fileprivate init(
        surfaceID: String,
        columns: Int,
        sourceRows: Int,
        firstSourceRow: Int,
        styles: [MobileTerminalRenderGridFrame.Style],
        rows: [[Cell]]
    ) {
        self.surfaceID = surfaceID
        self.columns = columns
        self.sourceRows = sourceRows
        self.firstSourceRow = firstSourceRow
        self.styles = styles
        self.stylesByID = styles.reduce(into: [:]) { result, style in
            result[style.id] = style
        }
        self.rows = rows
    }

    /// Plain terminal-width rows retained for text-only consumers and tests.
    public var textRows: [String] {
        rows.map { $0.map(\.text).joined() }
    }
}

private struct MutablePaneMapPreviewCell {
    var text = " "
    var styleID = 0
    var glyphID: Int?
    var columnSpan = 1

    var snapshot: MobileTerminalPaneMapPreview.Cell {
        MobileTerminalPaneMapPreview.Cell(
            text: text,
            styleID: styleID,
            columnSpan: columnSpan
        )
    }
}

public extension MobileTerminalRenderGridFrame {
    /// Resolves this frame into fixed terminal cells for a compact visual preview.
    ///
    /// Passing `nil` renders the complete visible terminal grid. A finite limit
    /// preserves the previous tail-window behavior for text-only callers.
    func paneMapPreview(
        maximumRows: Int? = nil
    ) -> MobileTerminalPaneMapPreview {
        guard columns > 0, rows > 0 else {
            return MobileTerminalPaneMapPreview(
                surfaceID: surfaceID,
                columns: max(0, columns),
                sourceRows: max(0, rows),
                firstSourceRow: 0,
                styles: styles,
                rows: []
            )
        }

        var spansByRow: [Int: [RowSpan]] = [:]
        var lastSpanRow: Int?
        for span in rowSpans where !span.text.isEmpty {
            spansByRow[span.row, default: []].append(span)
            lastSpanRow = max(lastSpanRow ?? span.row, span.row)
        }

        let rowRange: Range<Int>
        if let maximumRows {
            guard maximumRows > 0 else {
                return MobileTerminalPaneMapPreview(
                    surfaceID: surfaceID,
                    columns: columns,
                    sourceRows: rows,
                    firstSourceRow: 0,
                    styles: styles,
                    rows: []
                )
            }
            let boundedMaximumRows = min(rows, maximumRows)
            let lastContentRow = max(lastSpanRow ?? 0, cursor?.row ?? 0)
            let endRow = min(rows, max(lastContentRow + 1, boundedMaximumRows))
            let firstRow = max(0, endRow - boundedMaximumRows)
            rowRange = firstRow..<endRow
        } else {
            rowRange = 0..<rows
        }

        let previewRows = rowRange.map { row in
            paneMapPreviewCells(spans: spansByRow[row] ?? [])
        }
        return MobileTerminalPaneMapPreview(
            surfaceID: surfaceID,
            columns: columns,
            sourceRows: rows,
            firstSourceRow: rowRange.lowerBound,
            styles: styles,
            rows: previewRows
        )
    }

    /// Renders the content-bearing tail of this frame as terminal-width text.
    ///
    /// Each span uses the same producer-width resolution as VT replay. A wide
    /// grapheme occupies one string element followed by an empty continuation,
    /// so later content remains in its original terminal column. Spans are
    /// applied in source order; a later span that touches any cell of an older
    /// grapheme clears that whole grapheme before painting its replacement.
    ///
    /// - Parameter maximumRows: The maximum number of grid rows to return.
    /// - Returns: Preview rows ordered from the first included row to the last.
    func paneMapPreviewRows(maximumRows: Int = 20) -> [String] {
        paneMapPreview(maximumRows: maximumRows).textRows
    }

    private func paneMapPreviewCells(
        spans: [RowSpan]
    ) -> [MobileTerminalPaneMapPreview.Cell] {
        var cells = Array(repeating: MutablePaneMapPreviewCell(), count: columns)
        var glyphRanges: [Int: Range<Int>] = [:]
        var nextGlyphID = 0

        func clearGlyph(_ glyphID: Int) {
            guard let range = glyphRanges.removeValue(forKey: glyphID) else { return }
            for column in range where cells[column].glyphID == glyphID {
                cells[column] = MutablePaneMapPreviewCell()
            }
        }

        func place(_ text: String, at column: Int, width: Int, styleID: Int) {
            guard width > 0, column >= 0, column < columns else { return }
            let endColumn = min(columns, column + width)
            let range = column..<endColumn
            let overwrittenGlyphIDs = Set(range.compactMap { cells[$0].glyphID })
            for glyphID in overwrittenGlyphIDs {
                clearGlyph(glyphID)
            }

            let glyphID = nextGlyphID
            nextGlyphID += 1
            cells[column] = MutablePaneMapPreviewCell(
                text: text,
                styleID: styleID,
                glyphID: glyphID,
                columnSpan: range.count
            )
            for continuationColumn in range.dropFirst() {
                cells[continuationColumn] = MutablePaneMapPreviewCell(
                    text: "",
                    styleID: styleID,
                    glyphID: glyphID,
                    columnSpan: 0
                )
            }
            glyphRanges[glyphID] = range
        }

        for span in spans {
            guard !span.text.isEmpty else { continue }
            guard let widths = span.resolvedCharacterCellWidths else {
                place(
                    span.text,
                    at: span.column,
                    width: span.gridCellWidth,
                    styleID: span.styleID
                )
                continue
            }

            var column = span.column
            for (character, width) in zip(span.text, widths) {
                if width == 0 {
                    if column > 0,
                       let glyphID = cells[column - 1].glyphID,
                       let glyphRange = glyphRanges[glyphID] {
                        cells[glyphRange.lowerBound].text.append(contentsOf: String(character))
                    }
                    continue
                }
                place(String(character), at: column, width: width, styleID: span.styleID)
                column += width
            }
        }

        return cells.map(\.snapshot)
    }
}
