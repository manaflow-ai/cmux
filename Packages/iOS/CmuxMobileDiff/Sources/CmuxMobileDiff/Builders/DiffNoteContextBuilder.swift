/// Builds side-aware note context from immutable list snapshots.
struct DiffNoteContextBuilder: Sendable {
    /// Creates a context builder.
    init() {}

    /// Resolves a pressed line or hunk into prompt-ready context.
    /// - Parameters:
    ///   - file: File snapshot containing the unified source rows.
    ///   - presentedRow: The unified or split-projected row selected by the user.
    ///   - scope: Single-line or whole-hunk granularity.
    /// - Returns: Context when the row belongs to a loaded hunk.
    func context(
        file: DiffFileSnapshot,
        presentedRow: DiffRowSnapshot,
        scope: DiffNoteSelectionScope
    ) -> DiffNoteContext? {
        guard let sourceRow = selectedSourceRow(presentedRow, in: file.rows),
              let sourceIndex = file.rows.firstIndex(where: { $0.id == sourceRow.id }),
              let hunkIndex = file.rows[..<file.rows.index(after: sourceIndex)]
                .lastIndex(where: { $0.kind == .hunkHeader })
        else { return nil }

        let hunkRow = file.rows[hunkIndex]
        let endIndex = file.rows[file.rows.index(after: hunkIndex)...]
            .firstIndex(where: { $0.kind == .hunkHeader }) ?? file.rows.endIndex
        let hunkRows = Array(file.rows[file.rows.index(after: hunkIndex)..<endIndex])
            .filter(Self.isExcerptRow)
        let selectedRows = scope == .hunk ? hunkRows : [sourceRow]
        guard let reference = lineReference(for: scope == .hunk ? hunkRows : selectedRows),
              !selectedRows.isEmpty
        else { return nil }

        return DiffNoteContext(
            id: "\(scope):\(presentedRow.id)",
            path: file.path,
            lineReference: reference,
            hunkReference: canonicalHunkReference(hunkRow.text),
            excerpt: selectedRows.map(Self.promptLine).joined(separator: "\n")
        )
    }

    private func selectedSourceRow(
        _ presentedRow: DiffRowSnapshot,
        in rows: [DiffRowSnapshot]
    ) -> DiffRowSnapshot? {
        if let newID = presentedRow.splitNewSide?.sourceID,
           let row = rows.first(where: { $0.id == newID }) {
            return row
        }
        if let oldID = presentedRow.splitOldSide?.sourceID,
           let row = rows.first(where: { $0.id == oldID }) {
            return row
        }
        return rows.first(where: { $0.id == presentedRow.id })
    }

    private func lineReference(for rows: [DiffRowSnapshot]) -> DiffNoteLineReference? {
        if let newNumber = rows.lazy.compactMap(\.newLineNumber).first {
            return DiffNoteLineReference(number: newNumber, isOld: false)
        }
        if let oldNumber = rows.lazy.compactMap(\.oldLineNumber).first {
            return DiffNoteLineReference(number: oldNumber, isOld: true)
        }
        return nil
    }

    private func canonicalHunkReference(_ text: String) -> String {
        guard text.hasPrefix("@@"),
              let closing = text.dropFirst(2).range(of: "@@")
        else { return text }
        return String(text[..<closing.upperBound])
    }

    private static func isExcerptRow(_ row: DiffRowSnapshot) -> Bool {
        switch row.kind {
        case .context, .addition, .deletion, .noNewline:
            true
        default:
            false
        }
    }

    private static func promptLine(_ row: DiffRowSnapshot) -> String {
        switch row.kind {
        case .addition: "+\(row.text)"
        case .deletion: "-\(row.text)"
        case .noNewline: "\\ No newline at end of file"
        default: " \(row.text)"
        }
    }
}
