struct DiffQuickNoteTargetFactory: Sendable {
    func fileTarget(state: DiffFilePresentationState) -> DiffQuickNoteTarget {
        target(
            id: "file:\(state.file.summary.path)",
            path: state.file.summary.path,
            rows: state.rows,
            hunkHeader: state.rows.first(where: { $0.kind == .hunkHeader })?.text
        )
    }

    func hunkTarget(state: DiffFilePresentationState, hunkIndex: Int) -> DiffQuickNoteTarget {
        let rows = state.rows.filter { $0.hunkIndex == hunkIndex }
        return target(
            id: "hunk:\(state.file.summary.path):\(hunkIndex)",
            path: state.file.summary.path,
            rows: rows,
            hunkHeader: rows.first(where: { $0.kind == .hunkHeader })?.text
        )
    }

    private func target(
        id: String,
        path: String,
        rows: [DiffRowSnapshot],
        hunkHeader: String?
    ) -> DiffQuickNoteTarget {
        let oldLines = rows.compactMap(\.oldLine)
        let newLines = rows.compactMap(\.newLine)
        return DiffQuickNoteTarget(
            id: id,
            path: path,
            oldLineRange: lineRange(oldLines),
            newLineRange: lineRange(newLines),
            hunkHeader: hunkHeader,
            excerpt: rows.map(excerptLine).joined(separator: "\n")
        )
    }

    private func lineRange(_ lines: [Int]) -> ClosedRange<Int>? {
        guard let lower = lines.min(), let upper = lines.max() else { return nil }
        return lower...upper
    }

    private func excerptLine(_ row: DiffRowSnapshot) -> String {
        switch row.kind {
        case .hunkHeader: row.text
        case .context: " \(row.text)"
        case .addition: "+\(row.text)"
        case .deletion: "-\(row.text)"
        case .noNewline: "\\ \(row.text)"
        }
    }
}
