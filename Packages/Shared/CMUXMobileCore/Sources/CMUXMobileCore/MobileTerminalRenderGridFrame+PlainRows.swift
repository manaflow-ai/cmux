import Foundation

private func normalizedRenderGridRows(from text: String, maxRows: Int) -> [String] {
    var normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")
    if normalized.count > maxRows, normalized.last?.isEmpty == true {
        normalized.removeLast()
    }
    if normalized.count > maxRows {
        normalized = Array(normalized.prefix(maxRows))
    }
    while normalized.count < maxRows {
        normalized.append("")
    }
    return normalized
}

private func trimmingTrailingRenderGridBlanks(_ text: String) -> String {
    let scalars = text.unicodeScalars
    let space = UnicodeScalar(" ")
    let tab = UnicodeScalar("\t")
    var end = scalars.endIndex
    while end > scalars.startIndex {
        let previous = scalars.index(before: end)
        guard scalars[previous] == space || scalars[previous] == tab else { break }
        end = previous
    }
    return String(String.UnicodeScalarView(scalars[..<end]))
}

extension MobileTerminalRenderGridFrame {
    /// Creates a render-grid frame from newline-delimited viewport text.
    public static func fromPlainRows(
        surfaceID: String,
        stateSeq: UInt64,
        renderRevision: UInt64? = nil,
        columns: Int,
        rows: Int,
        text: String,
        cursor: Cursor? = nil,
        full: Bool = true,
        changedRows: Set<Int>? = nil
    ) throws -> MobileTerminalRenderGridFrame {
        let lines = normalizedRenderGridRows(from: text, maxRows: rows)
        let includedRows = changedRows ?? Set(0..<rows)
        let spans = lines.enumerated().compactMap { row, line -> RowSpan? in
            guard includedRows.contains(row) else { return nil }
            let trimmed = trimmingTrailingRenderGridBlanks(line)
            guard !trimmed.isEmpty else { return nil }
            let clipped = trimmed.clippedToRenderGridColumns(columns)
            guard !clipped.isEmpty else { return nil }
            return RowSpan(
                row: row,
                column: 0,
                styleID: 0,
                text: clipped
            )
        }
        return try MobileTerminalRenderGridFrame(
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            renderRevision: renderRevision,
            columns: columns,
            rows: rows,
            cursor: cursor,
            full: full,
            clearedRows: full ? [] : Array(includedRows.sorted()),
            rowSpans: spans
        )
    }

    /// Splits text into exactly `maxRows` normalized viewport rows.
    public static func normalizedPlainRows(from text: String, maxRows: Int) -> [String] {
        normalizedRenderGridRows(from: text, maxRows: maxRows)
    }
}
