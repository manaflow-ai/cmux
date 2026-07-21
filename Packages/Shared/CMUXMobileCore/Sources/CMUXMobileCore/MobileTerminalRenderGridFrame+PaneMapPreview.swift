private struct PaneMapPreviewCell {
    var text = " "
    var glyphID: Int?
}

public extension MobileTerminalRenderGridFrame {
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
        guard columns > 0, rows > 0, maximumRows > 0 else { return [] }

        var spansByRow: [Int: [RowSpan]] = [:]
        var lastSpanRow: Int?
        for span in rowSpans where !span.text.isEmpty {
            spansByRow[span.row, default: []].append(span)
            lastSpanRow = max(lastSpanRow ?? span.row, span.row)
        }

        let lastContentRow = max(lastSpanRow ?? 0, cursor?.row ?? 0)
        let minimumEndRow = min(rows, maximumRows)
        let endRow = min(rows, max(lastContentRow + 1, minimumEndRow))
        let firstRow = max(0, endRow - maximumRows)
        return (firstRow..<endRow).map { row in
            paneMapPreviewRow(spans: spansByRow[row] ?? [])
        }
    }

    private func paneMapPreviewRow(spans: [RowSpan]) -> String {
        var cells = Array(repeating: PaneMapPreviewCell(), count: columns)
        var glyphRanges: [Int: Range<Int>] = [:]
        var nextGlyphID = 0

        func clearGlyph(_ glyphID: Int) {
            guard let range = glyphRanges.removeValue(forKey: glyphID) else { return }
            for column in range where cells[column].glyphID == glyphID {
                cells[column] = PaneMapPreviewCell()
            }
        }

        func place(_ text: String, at column: Int, width: Int) {
            guard width > 0, column >= 0, column < columns else { return }
            let endColumn = min(columns, column + width)
            let range = column..<endColumn
            let overwrittenGlyphIDs = Set(range.compactMap { cells[$0].glyphID })
            for glyphID in overwrittenGlyphIDs {
                clearGlyph(glyphID)
            }

            let glyphID = nextGlyphID
            nextGlyphID += 1
            cells[column] = PaneMapPreviewCell(text: text, glyphID: glyphID)
            for continuationColumn in range.dropFirst() {
                cells[continuationColumn] = PaneMapPreviewCell(text: "", glyphID: glyphID)
            }
            glyphRanges[glyphID] = range
        }

        for span in spans {
            guard !span.text.isEmpty else { continue }
            guard let widths = span.resolvedCharacterCellWidths else {
                place(span.text, at: span.column, width: span.gridCellWidth)
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
                place(String(character), at: column, width: width)
                column += width
            }
        }

        return cells.map(\.text).joined()
    }
}
