/// One lazily rendered row of the diff body: a hunk header or a code line.
///
/// The diff body's lazy container iterates these flat rows instead of whole
/// hunks so a single enormous hunk (for example a truncated multi-thousand
/// line rewrite) never becomes one eagerly laid-out child, which froze
/// scrolling on large diffs.
struct DiffRowSnapshot: Identifiable, Equatable {
    let id: Int
    let line: DiffLine
    let hunkCopyText: String
    /// Whether this row is the header of a hunk after the first and should
    /// carry the inter-hunk gap above it.
    let leadingHunkGap: Bool

    static func rows(for document: FileDiffDocument) -> [DiffRowSnapshot] {
        var rows: [DiffRowSnapshot] = []
        rows.reserveCapacity(document.lines.count + document.hunks.count)
        for (hunkIndex, hunk) in document.hunks.enumerated() {
            let copyText = hunk.copyText
            rows.append(DiffRowSnapshot(
                id: rows.count,
                line: hunk.header,
                hunkCopyText: copyText,
                leadingHunkGap: hunkIndex > 0
            ))
            for line in hunk.lines {
                rows.append(DiffRowSnapshot(
                    id: rows.count,
                    line: line,
                    hunkCopyText: copyText,
                    leadingHunkGap: false
                ))
            }
        }
        return rows
    }
}
