/// Applies the transport row cap while retaining each hunk's coordinates.
struct DiffPageBuilder: Sendable {
    let rowLimit: Int

    func page(hunks: [DiffHunk], cursor: Int?) throws -> DiffFilePage {
        let offset = cursor ?? 0
        let totalRows = hunks.reduce(0) { $0 + $1.rows.count }
        guard offset >= 0, offset <= totalRows else {
            throw DiffEngineError.invalidRange
        }
        let upperBound = min(offset + rowLimit, totalRows)
        var globalIndex = 0
        var output: [DiffHunk] = []
        for hunk in hunks {
            let hunkStart = globalIndex
            let hunkEnd = hunkStart + hunk.rows.count
            globalIndex = hunkEnd
            let selectionStart = max(offset, hunkStart)
            let selectionEnd = min(upperBound, hunkEnd)
            guard selectionStart < selectionEnd else { continue }
            let localStart = selectionStart - hunkStart
            let localEnd = selectionEnd - hunkStart
            output.append(DiffHunk(
                oldStart: hunk.oldStart,
                oldLines: hunk.oldLines,
                newStart: hunk.newStart,
                newLines: hunk.newLines,
                sectionHeading: hunk.sectionHeading,
                rows: Array(hunk.rows[localStart..<localEnd])
            ))
        }
        return DiffFilePage(
            hunks: output,
            isBinary: false,
            tooLarge: false,
            nextCursor: upperBound < totalRows ? upperBound : nil
        )
    }
}
