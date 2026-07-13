import Foundation

extension MobileTerminalRenderGridFrame {
    public func plainRows() -> [String] {
        var rows = Array(repeating: "", count: self.rows)
        for span in rowSpans.sorted(by: { lhs, rhs in
            lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
        }) {
            guard rows.indices.contains(span.row) else { continue }
            let currentWidth = rows[span.row].count
            if currentWidth < span.column {
                rows[span.row].append(String(repeating: " ", count: span.column - currentWidth))
            }
            rows[span.row].append(span.text)
            let textWidth = span.text.count
            let padWidth = max(0, span.gridCellWidth - textWidth)
            if padWidth > 0 {
                rows[span.row].append(String(repeating: " ", count: padWidth))
            }
        }
        return rows
    }

    /// A per-row signature capturing both text **and resolved styling**, used
    /// to detect which rows changed between two full snapshots.
    ///
    /// Unlike ``plainRows()`` this changes when only a cell's style changes
    /// (for example a character typed over a dimmed shell autosuggestion, where
    /// the text is identical but the cell flips from faint to normal), so a
    /// style-only update is not dropped from the delta. The style is resolved
    /// to its visual attributes rather than keyed by ``Style/id``, because the
    /// producer reassigns style ids on every export.
    public func rowSignatures() -> [String] {
        var stylesByID: [Int: Style] = [:]
        for style in styles {
            stylesByID[style.id] = style
        }
        var spansByRow: [Int: [RowSpan]] = [:]
        for span in rowSpans {
            spansByRow[span.row, default: []].append(span)
        }
        var signatures = Array(repeating: "", count: rows)
        for row in 0..<rows {
            guard let spans = spansByRow[row] else { continue }
            signatures[row] = spans
                .sorted { $0.column < $1.column }
                .map { span in
                    let style = stylesByID[span.styleID] ?? .default
                    return "\(span.column):\(span.gridCellWidth):\(Self.styleSignature(style)):\(span.text)"
                }
                .joined(separator: "\u{1F}")
        }
        return signatures
    }

    private static func styleSignature(_ style: Style) -> String {
        let flags = [
            style.bold, style.faint, style.italic, style.underline, style.blink,
            style.inverse, style.invisible, style.strikethrough, style.overline,
        ].map { $0 ? "1" : "0" }.joined()
        return "\(style.foreground ?? "-")/\(style.background ?? "-")/\(flags)"
    }

    public func filteredRows(_ includedRows: Set<Int>, full: Bool) throws -> MobileTerminalRenderGridFrame {
        try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            renderRevision: renderRevision,
            columns: columns,
            rows: rows,
            cursor: cursor,
            full: full,
            clearedRows: full ? [] : Array(includedRows.sorted()),
            styles: styles,
            rowSpans: rowSpans.filter { includedRows.contains($0.row) },
            // Deltas only carry autowrap; DECOM needs a full snapshot because
            // restoring it homes the cursor and requires scroll-region state.
            activeScreen: activeScreen,
            modes: full ? modes : modes.filter(\.isDECAutowrapMode),
            terminalForeground: full ? terminalForeground : nil,
            terminalBackground: full ? terminalBackground : nil,
            terminalCursorColor: full ? terminalCursorColor : nil,
            scrollbackRows: full ? scrollbackRows : 0,
            scrollbackSpans: full ? scrollbackSpans : [],
            scrollForwardRows: full ? scrollForwardRows : 0,
            scrollForwardSpans: full ? scrollForwardSpans : [],
            primaryActiveRows: full ? primaryActiveRows : 0,
            primaryActiveSpans: full ? primaryActiveSpans : []
        )
    }
}
