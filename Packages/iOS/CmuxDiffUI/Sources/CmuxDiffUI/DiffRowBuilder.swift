import CmuxMobileRPC

struct DiffRowBuilder: Sendable {
    func rows(path: String, hunks: [MobileDiffHunk]) -> [DiffRowSnapshot] {
        var result: [DiffRowSnapshot] = []
        for (hunkIndex, hunk) in hunks.enumerated() {
            result.append(DiffRowSnapshot(
                id: "\(path):\(hunkIndex):header",
                kind: .hunkHeader,
                oldLine: nil,
                newLine: nil,
                text: headerText(for: hunk),
                hunkIndex: hunkIndex
            ))
            var oldLine = hunk.oldStart
            var newLine = hunk.newStart
            for (rowIndex, row) in hunk.rows.enumerated() {
                let assignment = lineAssignment(kind: row.kind, oldLine: oldLine, newLine: newLine)
                result.append(DiffRowSnapshot(
                    id: "\(path):\(hunkIndex):\(rowIndex)",
                    kind: assignment.kind,
                    oldLine: assignment.oldLine,
                    newLine: assignment.newLine,
                    text: row.text,
                    hunkIndex: hunkIndex
                ))
                oldLine += assignment.oldAdvance
                newLine += assignment.newAdvance
            }
        }
        return DiffRowIntralinePairer().apply(to: result)
    }

    private func lineAssignment(
        kind: MobileDiffRowKind,
        oldLine: Int,
        newLine: Int
    ) -> (kind: DiffRowKind, oldLine: Int?, newLine: Int?, oldAdvance: Int, newAdvance: Int) {
        switch kind {
        case .context:
            (.context, oldLine, newLine, 1, 1)
        case .add:
            (.addition, nil, newLine, 0, 1)
        case .del:
            (.deletion, oldLine, nil, 1, 0)
        case .noNewline:
            (.noNewline, nil, nil, 0, 0)
        }
    }

    private func headerText(for hunk: MobileDiffHunk) -> String {
        let range = "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"
        guard let heading = hunk.sectionHeading, !heading.isEmpty else { return range }
        return "\(range) \(heading)"
    }
}
