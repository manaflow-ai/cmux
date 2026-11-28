/// One lazily rendered row of the diff body: an expander, hunk header, or code line.
///
/// The diff body's lazy container iterates these flat rows instead of whole
/// hunks so a single enormous hunk (for example a truncated multi-thousand
/// line rewrite) never becomes one eagerly laid-out child, which froze
/// scrolling on large diffs.
struct DiffRowSnapshot: Identifiable, Sendable, Equatable {
    let id: String
    let content: DiffRowContent
    /// Whether this row is the header of a hunk after the first and should
    /// carry the inter-hunk gap above it.
    let leadingHunkGap: Bool

    var line: DiffLine? {
        guard case .line(let line, _) = content else { return nil }
        return line
    }

    var hunkCopyText: String {
        guard case .line(_, let copyText) = content else { return "" }
        return copyText
    }

    static func maximumLineNumber(in rows: [DiffRowSnapshot]) -> Int {
        rows.reduce(0) { current, row in
            guard case .line(let line, _) = row.content else { return current }
            return max(current, max(line.oldNumber ?? 0, line.newNumber ?? 0))
        }
    }

    static func rows(for document: FileDiffDocument) -> [DiffRowSnapshot] {
        var rows: [DiffRowSnapshot] = []
        rows.reserveCapacity(document.lines.count + document.hunks.count)
        for (hunkIndex, hunk) in document.hunks.enumerated() {
            let copyText = hunk.copyText
            rows.append(DiffRowSnapshot(
                id: "h:\(hunkIndex)",
                content: .line(hunk.header, hunkCopyText: copyText),
                leadingHunkGap: hunkIndex > 0
            ))
            for (lineIndex, line) in hunk.lines.enumerated() {
                rows.append(DiffRowSnapshot(
                    id: "l:\(hunkIndex):\(lineIndex)",
                    content: .line(line, hunkCopyText: copyText),
                    leadingHunkGap: false
                ))
            }
        }
        return rows
    }

    static func rows(
        for document: FileDiffDocument,
        expansionState: DiffExpansionState,
        currentFileLines: [String]?,
        fileKind: FileChangeKind
    ) -> [DiffRowSnapshot] {
        projectedRows(
            for: document,
            expansionState: expansionState,
            currentFileLines: currentFileLines,
            fileKind: fileKind,
            checksCancellation: false
        ) ?? []
    }

    static func cancellableRows(
        for document: FileDiffDocument,
        expansionState: DiffExpansionState,
        currentFileLines: [String]?,
        fileKind: FileChangeKind
    ) -> [DiffRowSnapshot]? {
        projectedRows(
            for: document,
            expansionState: expansionState,
            currentFileLines: currentFileLines,
            fileKind: fileKind,
            checksCancellation: true
        )
    }

    private static func projectedRows(
        for document: FileDiffDocument,
        expansionState: DiffExpansionState,
        currentFileLines: [String]?,
        fileKind: FileChangeKind,
        checksCancellation: Bool
    ) -> [DiffRowSnapshot]? {
        guard fileKind != .deleted, !document.isBinary else {
            return rows(for: document)
        }

        let gaps = DiffGap.gaps(
            for: document,
            currentFileLineCount: currentFileLines?.count
        )
        let gapsByID = Dictionary(uniqueKeysWithValues: gaps.map { ($0.id, $0) })
        var rows: [DiffRowSnapshot] = []
        rows.reserveCapacity(document.lines.count + document.hunks.count + 1)

        for (hunkIndex, hunk) in document.hunks.enumerated() {
            if checksCancellation, Task.isCancelled { return nil }
            let precedingGap = gapsByID[hunkIndex]
            if let precedingGap {
                guard append(
                    gap: precedingGap,
                    expansionState: expansionState,
                    currentFileLines: currentFileLines,
                    checksCancellation: checksCancellation,
                    to: &rows
                ) else { return nil }
            }
            let copyText = hunk.copyText
            rows.append(DiffRowSnapshot(
                id: "h:\(hunkIndex)",
                content: .line(hunk.header, hunkCopyText: copyText),
                leadingHunkGap: hunkIndex > 0 && precedingGap == nil
            ))
            for (lineIndex, line) in hunk.lines.enumerated() {
                if checksCancellation, Task.isCancelled { return nil }
                rows.append(DiffRowSnapshot(
                    id: "l:\(hunkIndex):\(lineIndex)",
                    content: .line(line, hunkCopyText: copyText),
                    leadingHunkGap: false
                ))
            }
        }
        if !document.truncated,
           let trailingGap = gapsByID[document.hunks.count] {
            guard append(
                gap: trailingGap,
                expansionState: expansionState,
                currentFileLines: currentFileLines,
                checksCancellation: checksCancellation,
                to: &rows
            ) else { return nil }
        }
        return rows
    }

    private static func append(
        gap: DiffGap,
        expansionState: DiffExpansionState,
        currentFileLines: [String]?,
        checksCancellation: Bool,
        to rows: inout [DiffRowSnapshot]
    ) -> Bool {
        guard let gapRange = gap.newLineRange else {
            rows.append(DiffRowSnapshot(
                id: "g:\(gap.id):unknown",
                content: .expander(DiffExpanderSnapshot(
                    gap: gap,
                    hiddenNewLineRange: nil
                )),
                leadingHunkGap: false
            ))
            return true
        }

        let revealedRanges = expansionState.revealedRanges(for: gap.id)
        let hiddenRanges = expansionState.hiddenRanges(in: gap)
        var cursor = gapRange.lowerBound
        while cursor < gapRange.upperBound {
            if checksCancellation, Task.isCancelled { return false }
            if let hidden = hiddenRanges.first(where: { $0.contains(cursor) }) {
                rows.append(DiffRowSnapshot(
                    id: "g:\(gap.id):\(hidden.lowerBound):\(hidden.upperBound)",
                    content: .expander(DiffExpanderSnapshot(
                        gap: gap,
                        hiddenNewLineRange: hidden
                    )),
                    leadingHunkGap: false
                ))
                cursor = hidden.upperBound
                continue
            }
            guard revealedRanges.contains(where: { $0.contains(cursor) }) else {
                cursor += 1
                continue
            }
            let textIndex = cursor - 1
            let text = currentFileLines.flatMap { lines in
                lines.indices.contains(textIndex) ? lines[textIndex] : nil
            } ?? ""
            rows.append(DiffRowSnapshot(
                id: "c:\(gap.id):\(cursor)",
                content: .line(DiffLine(
                    kind: .context,
                    text: text,
                    oldNumber: gap.oldLineNumber(forNewLine: cursor),
                    newNumber: cursor
                ), hunkCopyText: ""),
                leadingHunkGap: false
            ))
            cursor += 1
        }
        return true
    }
}
