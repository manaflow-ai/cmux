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
    /// Renderer-effective theme captured for this surface, when supplied by
    /// the producer.
    public let terminalTheme: TerminalTheme?
    /// Legacy raw OSC 10 foreground override.
    public let terminalForeground: String?
    /// Legacy raw OSC 11 background override.
    public let terminalBackground: String?
    private let usesDECReverseVideo: Bool

    fileprivate init(
        surfaceID: String,
        columns: Int,
        sourceRows: Int,
        firstSourceRow: Int,
        styles: [MobileTerminalRenderGridFrame.Style],
        terminalTheme: TerminalTheme?,
        terminalForeground: String?,
        terminalBackground: String?,
        usesDECReverseVideo: Bool,
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
        self.terminalTheme = terminalTheme
        self.terminalForeground = terminalForeground
        self.terminalBackground = terminalBackground
        self.usesDECReverseVideo = usesDECReverseVideo
        self.rows = rows
    }

    /// Plain terminal-width rows retained for text-only consumers and tests.
    public var textRows: [String] {
        rows.map { $0.map(\.text).joined() }
    }

    /// Resolves the terminal theme that painted this preview.
    ///
    /// Modern producers carry a renderer-effective theme directly. Legacy
    /// producers carry raw OSC 10/11 defaults plus DEC reverse-video state, so
    /// apply those values to the caller's surface theme before reversing them.
    public func resolvedTerminalTheme(fallback: TerminalTheme) -> TerminalTheme {
        if let terminalTheme {
            return terminalTheme.validatedOrDefault()
        }

        var resolved = fallback.validatedOrDefault()
        if let foreground = TerminalTheme.canonicalHex(terminalForeground) {
            resolved.foreground = foreground
        }
        if let background = TerminalTheme.canonicalHex(terminalBackground) {
            resolved.background = background
        }
        if usesDECReverseVideo {
            swap(&resolved.foreground, &resolved.background)
        }
        return resolved
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
    /// Passing `nil` renders the complete primary-screen history followed by
    /// the visible grid. Alternate-screen previews exclude primary scrollback.
    /// A finite limit retains the latest history-backed rows, while a preview
    /// without history preserves its previous content-aware window.
    func paneMapPreview(
        maximumRows: Int? = nil
    ) -> MobileTerminalPaneMapPreview {
        let usesDECReverseVideo = modes.contains {
            !$0.ansi && $0.code == 5 && $0.on
        }
        guard columns > 0, rows > 0 else {
            return MobileTerminalPaneMapPreview(
                surfaceID: surfaceID,
                columns: max(0, columns),
                sourceRows: max(0, rows),
                firstSourceRow: 0,
                styles: styles,
                terminalTheme: terminalTheme,
                terminalForeground: terminalForeground,
                terminalBackground: terminalBackground,
                usesDECReverseVideo: usesDECReverseVideo,
                rows: []
            )
        }

        let includedScrollbackRows = activeScreen == .primary ? scrollbackRows : 0
        let sourceRows = includedScrollbackRows + rows
        var spansByRow: [Int: [RowSpan]] = [:]
        var lastSpanRow: Int?
        if includedScrollbackRows > 0 {
            for span in scrollbackSpans where !span.text.isEmpty {
                spansByRow[span.row, default: []].append(span)
                lastSpanRow = max(lastSpanRow ?? span.row, span.row)
            }
        }
        for span in rowSpans where !span.text.isEmpty {
            let sourceRow = includedScrollbackRows + span.row
            spansByRow[sourceRow, default: []].append(span)
            lastSpanRow = max(lastSpanRow ?? sourceRow, sourceRow)
        }

        let rowRange: Range<Int>
        if let maximumRows {
            guard maximumRows > 0 else {
                return MobileTerminalPaneMapPreview(
                    surfaceID: surfaceID,
                    columns: columns,
                    sourceRows: sourceRows,
                    firstSourceRow: 0,
                    styles: styles,
                    terminalTheme: terminalTheme,
                    terminalForeground: terminalForeground,
                    terminalBackground: terminalBackground,
                    usesDECReverseVideo: usesDECReverseVideo,
                    rows: []
                )
            }
            let boundedMaximumRows = min(sourceRows, maximumRows)
            if includedScrollbackRows > 0 {
                let firstRow = sourceRows - boundedMaximumRows
                rowRange = firstRow..<sourceRows
            } else {
                let lastContentRow = max(lastSpanRow ?? 0, cursor?.row ?? 0)
                let endRow = min(sourceRows, max(lastContentRow + 1, boundedMaximumRows))
                let firstRow = max(0, endRow - boundedMaximumRows)
                rowRange = firstRow..<endRow
            }
        } else {
            rowRange = 0..<sourceRows
        }

        let previewRows = rowRange.map { row in
            paneMapPreviewCells(spans: spansByRow[row] ?? [])
        }
        return MobileTerminalPaneMapPreview(
            surfaceID: surfaceID,
            columns: columns,
            sourceRows: sourceRows,
            firstSourceRow: rowRange.lowerBound,
            styles: styles,
            terminalTheme: terminalTheme,
            terminalForeground: terminalForeground,
            terminalBackground: terminalBackground,
            usesDECReverseVideo: usesDECReverseVideo,
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
