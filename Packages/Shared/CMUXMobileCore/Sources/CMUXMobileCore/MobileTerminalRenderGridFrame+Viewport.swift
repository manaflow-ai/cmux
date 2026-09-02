import Foundation

extension MobileTerminalRenderGridFrame {
    /// Maximum number of wrapped scrollback lines retained by one client
    /// projection. Visible rows are always preserved; older projected history
    /// is truncated at this bound to keep narrow viewport requests bounded.
    public static let maximumProjectedScrollbackLines = 16_384

    private struct ViewportCell {
        var text: String
        let styleID: Int
        let width: Int
        let sourceColumn: Int
    }

    private struct ViewportLine {
        let sourceRow: Int
        let cells: [ViewportCell]
    }

    /// Projects a complete frame into a client-local cell viewport.
    ///
    /// The projection wraps each source row at `columns` and keeps the newest
    /// `rows` projected lines. It never calls a terminal resize operation, so
    /// the PTY, Mac pane, and other connections remain at the native grid.
    /// Style spans, cursor metadata, scrollback, and producer revisions are
    /// retained in the projected frame. Delta frames are returned unchanged;
    /// callers should project the full replay that establishes their baseline.
    ///
    /// - Parameters:
    ///   - columns: Client-local column count.
    ///   - rows: Client-local row count.
    /// - Returns: A full frame at the requested dimensions, or `self` when the
    ///   dimensions are invalid or already match.
    public func projectedViewport(columns: Int, rows: Int) -> Self {
        guard full,
              columns > 0,
              rows > 0,
              columns != self.columns || rows != self.rows else {
            return self
        }

        let visibleLines = wrappedLines(
            rows: rowSpans,
            rowCount: self.rows,
            sourceColumns: self.columns,
            targetColumns: columns
        )
        let firstVisibleLine = max(0, visibleLines.count - rows)
        let selectedVisibleLines = Array(visibleLines.suffix(rows))
        let visibleSpans = Self.spans(
            from: selectedVisibleLines,
            targetColumns: columns,
            rowOffset: 0
        )

        let scrollbackLines = wrappedLines(
            rows: scrollbackSpans,
            rowCount: scrollbackRows,
            sourceColumns: self.columns,
            targetColumns: columns,
            maximumLines: Self.maximumProjectedScrollbackLines
        )
        let projectedScrollbackSpans = Self.spans(
            from: scrollbackLines,
            targetColumns: columns,
            rowOffset: 0
        )

        var projectedCursor: Cursor?
        if let cursor {
            let matchingLineIndices = visibleLines.indices.filter {
                $0 >= firstVisibleLine && visibleLines[$0].sourceRow == cursor.row
            }
            for lineIndex in matchingLineIndices {
                let line = visibleLines[lineIndex]
                var column = 0
                for cell in line.cells {
                    if cursor.column >= cell.sourceColumn,
                       cursor.column < cell.sourceColumn + max(cell.width, 1) {
                        var mapped = cursor
                        mapped.row = lineIndex - firstVisibleLine
                        mapped.column = min(max(0, column), columns - 1)
                        projectedCursor = mapped
                        break
                    }
                    column += cell.width
                }
                if projectedCursor != nil { break }
            }

            // `fromPlainRows` intentionally trims trailing default cells from
            // spans. A cursor parked in one of those cells is still visible in
            // the projected row; map it relative to the last wrapped line
            // instead of dropping the cursor entirely. Empty rows retain the
            // historical column-zero behavior.
            if projectedCursor == nil, let lineIndex = matchingLineIndices.last {
                let line = visibleLines[lineIndex]
                let isEmptyRow = line.cells.allSatisfy {
                    $0.styleID == 0 && $0.width == 1 && $0.text == " "
                }
                var mapped = cursor
                mapped.row = lineIndex - firstVisibleLine
                if isEmptyRow {
                    mapped.column = 0
                } else {
                    let lineStart = line.cells.first?.sourceColumn ?? cursor.column
                    mapped.column = min(
                        max(0, cursor.column - lineStart),
                        columns - 1
                    )
                }
                projectedCursor = mapped
            }
        }

        return (try? Self(
            format: format,
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            renderEpoch: renderEpoch,
            renderRevision: renderRevision,
            emissionRevision: emissionRevision,
            columns: columns,
            rows: rows,
            cursor: projectedCursor,
            full: true,
            styles: styles,
            rowSpans: visibleSpans,
            activeScreen: activeScreen,
            modes: modes,
            terminalForeground: terminalForeground,
            terminalBackground: terminalBackground,
            terminalCursorColor: terminalCursorColor,
            terminalTheme: terminalTheme,
            terminalConfigTheme: terminalConfigTheme,
            terminalThemeRevision: terminalThemeRevision,
            scrollbackRows: scrollbackLines.count,
            scrollbackSpans: projectedScrollbackSpans,
            anchor: anchor,
            historyRows: historyRows,
            rowSpaceRevision: rowSpaceRevision
        )) ?? self
    }

    /// Returns the projected visible rows as plain text.
    public func projectedViewportText(columns: Int, rows: Int) -> String {
        projectedViewport(columns: columns, rows: rows)
            .plainRows()
            .joined(separator: "\n")
    }

    private func wrappedLines(
        rows: [RowSpan],
        rowCount: Int,
        sourceColumns: Int,
        targetColumns: Int,
        maximumLines: Int? = nil
    ) -> [ViewportLine] {
        // Canonicalize the entire span list once. The previous implementation
        // sorted every row independently, multiplying sort overhead for large
        // scrollback exports and repeated local-socket projections.
        let canonicalRows = Self.canonicalSpans(rows)
        var spansByRow: [Int: [RowSpan]] = [:]
        for span in canonicalRows {
            spansByRow[span.row, default: []].append(span)
        }
        let resolvedRowCount = max(0, rowCount)
        let sourceRows: [Int]
        if let maximumLines {
            guard maximumLines > 0, resolvedRowCount > 0 else { return [] }
            // Scrollback is retained newest-first while wrapping so a narrow
            // client cannot force allocation for every historical row. The
            // final flatten restores oldest-to-newest wire order.
            sourceRows = Array(stride(
                from: resolvedRowCount - 1,
                through: 0,
                by: -1
            ))
        } else {
            sourceRows = Array(0..<resolvedRowCount)
        }
        var result: [ViewportLine] = []
        var newestFirstRows: [[ViewportLine]] = []
        var newestFirstLineCount = 0
        for sourceRow in sourceRows {
            var cells = (0..<max(0, sourceColumns)).map { index in
                ViewportCell(text: " ", styleID: 0, width: 1, sourceColumn: index)
            }
            for span in spansByRow[sourceRow] ?? [] {
                var column = span.column
                var remainingWidth = span.gridCellWidth
                for character in span.text {
                    let estimatedWidth = character.renderGridEstimatedCellWidth
                    if estimatedWidth == 0 {
                        if column > 0, column - 1 < cells.count {
                            cells[column - 1].text.append(character)
                        }
                        continue
                    }
                    guard column < cells.count, remainingWidth > 0 else { break }
                    let width = min(
                        min(max(1, estimatedWidth), remainingWidth),
                        cells.count - column
                    )
                    cells[column] = ViewportCell(
                        text: String(character),
                        styleID: span.styleID,
                        width: width,
                        sourceColumn: column
                    )
                    if width > 1 {
                        for tail in 1..<width {
                            cells[column + tail] = ViewportCell(
                                text: "", styleID: span.styleID, width: 0,
                                sourceColumn: column
                            )
                        }
                    }
                    column += width
                    remainingWidth -= width
                }
                // A span's explicit cell width can include trailing blank
                // cells (and can differ from our conservative Unicode-width
                // estimate for ambiguous characters). Keep those cells in
                // the source grid so wrapping never shifts later spans.
                while remainingWidth > 0, column < cells.count {
                    cells[column] = ViewportCell(
                        text: " ",
                        styleID: span.styleID,
                        width: 1,
                        sourceColumn: column
                    )
                    column += 1
                    remainingWidth -= 1
                }
            }

            while cells.last?.styleID == 0,
                  cells.last?.width == 1,
                  cells.last?.text == " " {
                cells.removeLast()
            }
            if cells.isEmpty {
                cells = [ViewportCell(
                    text: " ", styleID: 0, width: 1, sourceColumn: 0
                )]
            }

            var lineCells: [ViewportCell] = []
            var rowLines: [ViewportLine] = []
            var lineWidth = 0
            for cell in cells where cell.width > 0 {
                guard cell.width <= targetColumns else {
                    // A wide source glyph cannot fit in a one-cell target
                    // line. Leave that cell blank rather than creating an
                    // invalid span wider than the projected grid.
                    if lineWidth > 0 {
                        rowLines.append(ViewportLine(sourceRow: sourceRow, cells: lineCells))
                        lineCells.removeAll(keepingCapacity: true)
                        lineWidth = 0
                    }
                    rowLines.append(ViewportLine(
                        sourceRow: sourceRow,
                        cells: [ViewportCell(
                            text: " ",
                            styleID: 0,
                            width: targetColumns,
                            sourceColumn: cell.sourceColumn
                        )]
                    ))
                    continue
                }
                if lineWidth > 0, lineWidth + cell.width > targetColumns {
                    rowLines.append(ViewportLine(sourceRow: sourceRow, cells: lineCells))
                    lineCells.removeAll(keepingCapacity: true)
                    lineWidth = 0
                }
                lineCells.append(cell)
                lineWidth += cell.width
                if lineWidth == targetColumns {
                    rowLines.append(ViewportLine(sourceRow: sourceRow, cells: lineCells))
                    lineCells.removeAll(keepingCapacity: true)
                    lineWidth = 0
                }
            }
            if !lineCells.isEmpty || cells.isEmpty {
                rowLines.append(ViewportLine(sourceRow: sourceRow, cells: lineCells))
            }

            if let maximumLines {
                let remaining = maximumLines - newestFirstLineCount
                guard remaining > 0 else { break }
                let retained = Array(rowLines.suffix(remaining))
                newestFirstRows.append(retained)
                newestFirstLineCount += retained.count
                if rowLines.count >= remaining {
                    break
                }
            } else {
                result.append(contentsOf: rowLines)
            }
        }
        if maximumLines != nil {
            return newestFirstRows.reversed().flatMap { $0 }
        }
        return result
    }

    private static func spans(
        from lines: [ViewportLine],
        targetColumns: Int,
        rowOffset: Int
    ) -> [RowSpan] {
        var result: [RowSpan] = []
        for (lineIndex, line) in lines.enumerated() {
            var column = 0
            var runStyle: Int?
            var runStartColumn = 0
            var runText = ""
            var runWidth = 0
            func flush() {
                guard let style = runStyle, runWidth > 0, !runText.isEmpty else {
                    runStyle = nil
                    runText = ""
                    runWidth = 0
                    return
                }
                result.append(RowSpan(
                    row: lineIndex + rowOffset,
                    column: runStartColumn,
                    styleID: style,
                    text: runText,
                    cellWidth: runWidth
                ))
                runStyle = nil
                runText = ""
                runWidth = 0
            }
            for cell in line.cells where cell.width > 0 {
                let text = cell.text.isEmpty ? " " : cell.text
                let isDefaultBlank = cell.styleID == 0 && text == " "
                if isDefaultBlank {
                    flush()
                } else if runStyle == cell.styleID {
                    runText.append(contentsOf: text)
                    runWidth += cell.width
                } else {
                    flush()
                    runStyle = cell.styleID
                    runStartColumn = column
                    runText = text
                    runWidth = cell.width
                }
                column += cell.width
            }
            flush()
        }
        _ = targetColumns
        return result
    }
}

extension String {
    /// Wraps terminal text to a client-local width and optionally keeps only
    /// the newest viewport rows. This is used when a render-grid export is not
    /// available and a socket read falls back to VT text.
    public func projectedTerminalText(
        columns: Int,
        rows: Int,
        keepAllRows: Bool
    ) -> String {
        guard columns > 0, rows > 0 else { return self }
        let sourceLines = replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var projected: [String] = []
        for sourceLine in sourceLines {
            var line = ""
            var width = 0
            for character in sourceLine {
                let characterWidth = min(
                    max(1, character.renderGridEstimatedCellWidth),
                    columns
                )
                if width > 0, width + characterWidth > columns {
                    projected.append(line)
                    line = ""
                    width = 0
                }
                line.append(character)
                width += characterWidth
                if width == columns {
                    projected.append(line)
                    line = ""
                    width = 0
                }
            }
            if !line.isEmpty || sourceLine.isEmpty {
                projected.append(line)
            }
        }
        if !keepAllRows, projected.count > rows {
            projected = Array(projected.suffix(rows))
        }
        return projected.joined(separator: "\n")
    }
}
