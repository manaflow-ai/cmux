import CMUXMobileCore

/// Applies full and delta render-grid frames into one renderer-ready baseline.
struct PreviewGridAccumulator {
    enum ApplyResult {
        case applied(PreviewGridSnapshot)
        case ignored
        case needsBaseline
    }

    private(set) var snapshot: PreviewGridSnapshot?

    mutating func reset() {
        snapshot = nil
    }

    mutating func apply(_ frame: MobileTerminalRenderGridFrame) -> ApplyResult {
        if let snapshot, frame.stateSeq < snapshot.stateSeq {
            return .ignored
        }
        if frame.full {
            let next = makeFullSnapshot(frame)
            snapshot = next
            return .applied(next)
        }
        guard let current = snapshot,
              current.hasBaseline,
              current.columns == frame.columns,
              current.rows == frame.rows,
              current.activeScreen == frame.activeScreen else {
            return .needsBaseline
        }

        var linesByRow = Dictionary(uniqueKeysWithValues: current.lines.map { ($0.row, $0) })
        let replacedRows = Set(frame.clearedRows).union(frame.rowSpans.map(\.row))
        let spansByRow = resolvedSpansByRow(frame)
        for row in replacedRows {
            linesByRow[row] = PreviewGridLine(row: row, spans: spansByRow[row] ?? [])
        }
        let next = PreviewGridSnapshot(
            surfaceID: frame.surfaceID,
            stateSeq: frame.stateSeq,
            columns: frame.columns,
            rows: frame.rows,
            activeScreen: frame.activeScreen,
            lines: (0..<frame.rows).map { linesByRow[$0] ?? PreviewGridLine(row: $0, spans: []) },
            hasBaseline: true
        )
        snapshot = next
        return .applied(next)
    }

    private func makeFullSnapshot(_ frame: MobileTerminalRenderGridFrame) -> PreviewGridSnapshot {
        let spansByRow = resolvedSpansByRow(frame)
        return PreviewGridSnapshot(
            surfaceID: frame.surfaceID,
            stateSeq: frame.stateSeq,
            columns: frame.columns,
            rows: frame.rows,
            activeScreen: frame.activeScreen,
            lines: (0..<frame.rows).map { row in
                PreviewGridLine(row: row, spans: spansByRow[row] ?? [])
            },
            hasBaseline: true
        )
    }

    private func resolvedSpansByRow(
        _ frame: MobileTerminalRenderGridFrame
    ) -> [Int: [PreviewGridSpan]] {
        let stylesByID = Dictionary(uniqueKeysWithValues: frame.styles.map { ($0.id, $0) })
        var spansByRow: [Int: [PreviewGridSpan]] = [:]
        for span in frame.rowSpans {
            let style = stylesByID[span.styleID] ?? .default
            spansByRow[span.row, default: []].append(PreviewGridSpan(
                column: span.column,
                cellWidth: span.resolvedCellWidth,
                text: span.text,
                style: PreviewGridStyle(renderGridStyle: style)
            ))
        }
        for row in spansByRow.keys {
            spansByRow[row]?.sort { $0.column < $1.column }
        }
        return spansByRow
    }
}
