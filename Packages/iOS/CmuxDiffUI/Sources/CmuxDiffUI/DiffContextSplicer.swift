import CmuxMobileRPC

struct DiffContextSplicer: Sendable {
    private let pageLineCount = 20
    private let practicalEndOfFile = 1_000_000_000

    func ranges(
        for direction: DiffContextExpansionRequest.Direction,
        hunkIndex: Int,
        hunks: [MobileDiffHunk]
    ) -> [ClosedRange<Int>] {
        guard hunks.indices.contains(hunkIndex) else { return [] }
        let hunk = hunks[hunkIndex]
        let beforeUpper = hunk.newStart - 1
        let previousEnd = hunkIndex > 0
            ? hunks[hunkIndex - 1].newStart + hunks[hunkIndex - 1].newLines
            : 1
        let beforeLower = max(1, previousEnd)

        let afterLower = max(1, hunk.newStart + hunk.newLines)
        let afterUpper = hunkIndex + 1 < hunks.count
            ? hunks[hunkIndex + 1].newStart - 1
            : practicalEndOfFile

        let allBefore = range(lower: beforeLower, upper: beforeUpper)
        let allAfter = range(lower: afterLower, upper: afterUpper)
        switch direction {
        case .up:
            return range(
                lower: max(beforeLower, beforeUpper - pageLineCount + 1),
                upper: beforeUpper
            ).map { [$0] } ?? []
        case .down:
            return range(
                lower: afterLower,
                upper: min(afterUpper, afterLower + pageLineCount - 1)
            ).map { [$0] } ?? []
        case .all:
            return [allBefore, allAfter].compactMap { $0 }
        }
    }

    func splice(
        rows: [String],
        range: ClosedRange<Int>,
        into hunks: [MobileDiffHunk],
        hunkIndex: Int
    ) -> [MobileDiffHunk] {
        guard !rows.isEmpty, hunks.indices.contains(hunkIndex) else { return hunks }
        var result = hunks
        let hunk = result[hunkIndex]
        let isBefore = range.upperBound < hunk.newStart
        let delta = isBefore
            ? hunk.newStart - hunk.oldStart
            : hunk.newStart - hunk.oldStart + hunk.newLines - hunk.oldLines
        let numberedRows = rows.enumerated().map { offset, text in
            let newLine = range.lowerBound + offset
            return MobileDiffRow(
                kind: .context,
                oldNo: newLine - delta,
                newNo: newLine,
                text: text
            )
        }

        if isBefore {
            result[hunkIndex] = MobileDiffHunk(
                oldStart: numberedRows[0].oldNo ?? hunk.oldStart - numberedRows.count,
                oldLines: hunk.oldLines + numberedRows.count,
                newStart: range.lowerBound,
                newLines: hunk.newLines + numberedRows.count,
                sectionHeading: hunk.sectionHeading,
                rows: numberedRows + hunk.rows
            )
        } else {
            result[hunkIndex] = MobileDiffHunk(
                oldStart: hunk.oldStart,
                oldLines: hunk.oldLines + numberedRows.count,
                newStart: hunk.newStart,
                newLines: hunk.newLines + numberedRows.count,
                sectionHeading: hunk.sectionHeading,
                rows: hunk.rows + numberedRows
            )
        }
        return result
    }

    private func range(lower: Int, upper: Int) -> ClosedRange<Int>? {
        lower <= upper ? lower...upper : nil
    }
}
