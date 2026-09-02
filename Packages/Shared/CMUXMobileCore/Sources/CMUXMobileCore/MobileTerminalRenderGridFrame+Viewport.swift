import Foundation

extension MobileTerminalRenderGridFrame {
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
            targetColumns: columns
        )
        let projectedScrollbackSpans = Self.spans(
            from: scrollbackLines,
            targetColumns: columns,
            rowOffset: 0
        )

        var projectedCursor: Cursor?
        if let cursor,
           let lineIndex = visibleLines.firstIndex(where: { line in
               guard line.sourceRow == cursor.row else { return false }
               var position = 0
               for cell in line.cells {
                   if cursor.column >= cell.sourceColumn,
                      cursor.column < cell.sourceColumn + max(cell.width, 1) {
                       return true
                   }
                   position += cell.width
               }
               return position == 0 && cursor.column == 0
           }),
           lineIndex >= firstVisibleLine {
            let line = visibleLines[lineIndex]
            var column = 0
            for cell in line.cells {
                if cursor.column >= cell.sourceColumn,
                   cursor.column < cell.sourceColumn + max(cell.width, 1) {
                    break
                }
                column += cell.width
            }
            var mapped = cursor
            mapped.row = lineIndex - firstVisibleLine
            mapped.column = min(max(0, column), columns - 1)
            projectedCursor = mapped
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
        targetColumns: Int
    ) -> [ViewportLine] {
        // Canonicalize the entire span list once. The previous implementation
        // sorted every row independently, multiplying sort overhead for large
        // scrollback exports and repeated local-socket projections.
        let canonicalRows = Self.canonicalSpans(rows)
        var spansByRow: [Int: [RowSpan]] = [:]
        for span in canonicalRows {
            spansByRow[span.row, default: []].append(span)
        }
        var result: [ViewportLine] = []
        for sourceRow in 0..<max(0, rowCount) {
            var cells = Array(repeating: ViewportCell(
                text: " ", styleID: 0, width: 1, sourceColumn: 0
            ), count: max(0, sourceColumns))
            for index in cells.indices {
                cells[index] = ViewportCell(
                    text: " ", styleID: 0, width: 1, sourceColumn: index
                )
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
            var lineWidth = 0
            for cell in cells where cell.width > 0 {
                guard cell.width <= targetColumns else {
                    // A wide source glyph cannot fit in a one-cell target
                    // line. Leave that cell blank rather than creating an
                    // invalid span wider than the projected grid.
                    if lineWidth > 0 {
                        result.append(ViewportLine(sourceRow: sourceRow, cells: lineCells))
                        lineCells.removeAll(keepingCapacity: true)
                        lineWidth = 0
                    }
                    result.append(ViewportLine(
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
                    result.append(ViewportLine(sourceRow: sourceRow, cells: lineCells))
                    lineCells.removeAll(keepingCapacity: true)
                    lineWidth = 0
                }
                lineCells.append(cell)
                lineWidth += cell.width
                if lineWidth == targetColumns {
                    result.append(ViewportLine(sourceRow: sourceRow, cells: lineCells))
                    lineCells.removeAll(keepingCapacity: true)
                    lineWidth = 0
                }
            }
            if !lineCells.isEmpty || cells.isEmpty {
                result.append(ViewportLine(sourceRow: sourceRow, cells: lineCells))
            }
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
