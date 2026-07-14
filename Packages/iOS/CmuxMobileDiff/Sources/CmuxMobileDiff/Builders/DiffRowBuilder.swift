internal import CmuxMobileRPC

/// Converts wire hunks into immutable unified-mode rows.
struct DiffRowBuilder: Sendable {
    /// Maximum adjacent deletion/addition run eligible for intraline work.
    let maximumIntralineRun: Int
    private let intraline: IntralineWordDiff

    /// Creates a unified row builder.
    /// - Parameters:
    ///   - maximumIntralineRun: Run cap applied independently to deleted and added rows.
    ///   - intraline: Bounded line differ used for paired rows.
    init(maximumIntralineRun: Int = 100, intraline: IntralineWordDiff = IntralineWordDiff()) {
        self.maximumIntralineRun = maximumIntralineRun
        self.intraline = intraline
    }

    /// Builds file, hunk, code, marker, and expansion rows for unified rendering.
    /// - Parameters:
    ///   - file: Wire file summary.
    ///   - hunks: Ordered wire hunks, potentially assembled from multiple pages.
    ///   - includeEOFGap: Whether to append an open-ended expansion gap.
    /// - Returns: Renderable rows beginning with a file-header sentinel.
    func rows(
        file: MobileChangesFile,
        hunks: [MobileChangesHunk],
        includeEOFGap: Bool = true,
        mode: DiffRenderingMode = .unified
    ) -> [DiffRowSnapshot] {
        var result = [DiffRowSnapshot(id: "file:\(file.path)", kind: .fileHeader, text: file.path)]
        guard !hunks.isEmpty else { return result }

        var previousNewEnd: Int?
        var previousDelta = 0
        for (hunkIndex, hunk) in hunks.enumerated() {
            let gapStart = previousNewEnd ?? 1
            let gapEnd = hunk.newStart - 1
            if gapStart <= gapEnd {
                let delta = previousNewEnd == nil ? hunk.oldStart - hunk.newStart : previousDelta
                result.append(gapRow(file: file.path, index: hunkIndex, start: gapStart, end: gapEnd, delta: delta))
            }

            let section = hunk.sectionHeading.map { " \($0)" } ?? ""
            result.append(DiffRowSnapshot(
                id: "hunk:\(file.path):\(hunkIndex)",
                kind: .hunkHeader,
                text: "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@\(section)"
            ))
            result.append(contentsOf: codeRows(file: file.path, hunkIndex: hunkIndex, rows: hunk.rows))
            previousNewEnd = hunk.newStart + hunk.newLines
            previousDelta = (hunk.oldStart + hunk.oldLines) - (hunk.newStart + hunk.newLines)
        }

        if includeEOFGap, let previousNewEnd {
            result.append(gapRow(
                file: file.path,
                index: hunks.count,
                start: previousNewEnd,
                end: nil,
                delta: previousDelta
            ))
        }
        return projectedRows(result, mode: mode)
    }

    /// Projects existing unified rows through the same unified/split seam.
    /// - Parameters:
    ///   - rows: Stable unified rows, including headings and expansion controls.
    ///   - mode: Concrete row layout.
    /// - Returns: Original rows or side-by-side paired rows with alignment padding.
    func projectedRows(_ rows: [DiffRowSnapshot], mode: DiffRenderingMode) -> [DiffRowSnapshot] {
        guard mode == .split else { return rows }
        var result: [DiffRowSnapshot] = []
        var index = 0
        while index < rows.count {
            let row = rows[index]
            switch row.kind {
            case .context:
                result.append(splitRow(old: row, new: row))
                index += 1
            case .deletion:
                let deletionStart = index
                while index < rows.count, rows[index].kind == .deletion { index += 1 }
                let additionStart = index
                while index < rows.count, rows[index].kind == .addition { index += 1 }
                let deletions = Array(rows[deletionStart..<additionStart])
                let additions = Array(rows[additionStart..<index])
                for offset in 0..<max(deletions.count, additions.count) {
                    result.append(splitRow(
                        old: offset < deletions.count ? deletions[offset] : nil,
                        new: offset < additions.count ? additions[offset] : nil
                    ))
                }
            case .addition:
                result.append(splitRow(old: nil, new: row))
                index += 1
            default:
                result.append(row)
                index += 1
            }
        }
        return result
    }

    private func gapRow(file: String, index: Int, start: Int, end: Int?, delta: Int) -> DiffRowSnapshot {
        let id = "gap:\(file):\(index):\(start):\(end.map(String.init) ?? "eof")"
        return DiffRowSnapshot(
            id: id,
            kind: .expansionGap,
            text: "",
            expansionGap: DiffExpansionGap(id: id, newStart: start, newEnd: end, oldLineDelta: delta)
        )
    }

    private func codeRows(file: String, hunkIndex: Int, rows: [MobileChangesDiffRow]) -> [DiffRowSnapshot] {
        var result = rows.enumerated().map { offset, row in
            DiffRowSnapshot(
                id: "code:\(file):\(hunkIndex):\(offset)",
                kind: kind(row.kind),
                oldLineNumber: row.oldNo,
                newLineNumber: row.newNo,
                marker: marker(row.kind),
                text: row.text
            )
        }
        applyIntralineRanges(to: &result)
        return result
    }

    private func applyIntralineRanges(to rows: inout [DiffRowSnapshot]) {
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .deletion else { index += 1; continue }
            let deletionStart = index
            while index < rows.count, rows[index].kind == .deletion { index += 1 }
            let additionStart = index
            while index < rows.count, rows[index].kind == .addition { index += 1 }
            let deletionCount = additionStart - deletionStart
            let additionCount = index - additionStart
            guard additionCount > 0,
                  deletionCount <= maximumIntralineRun,
                  additionCount <= maximumIntralineRun else { continue }
            for pair in 0..<min(deletionCount, additionCount) {
                let oldIndex = deletionStart + pair
                let newIndex = additionStart + pair
                let ranges = intraline.ranges(old: rows[oldIndex].text, new: rows[newIndex].text)
                rows[oldIndex] = replacingRanges(of: rows[oldIndex], with: ranges.old)
                rows[newIndex] = replacingRanges(of: rows[newIndex], with: ranges.new)
            }
        }
    }

    private func replacingRanges(of row: DiffRowSnapshot, with ranges: [DiffCharacterRange]) -> DiffRowSnapshot {
        DiffRowSnapshot(
            id: row.id,
            kind: row.kind,
            oldLineNumber: row.oldLineNumber,
            newLineNumber: row.newLineNumber,
            marker: row.marker,
            text: row.text,
            intralineRanges: ranges,
            expansionGap: row.expansionGap,
            highlightedText: row.highlightedText,
            splitOldSide: row.splitOldSide,
            splitNewSide: row.splitNewSide,
            sourceRowIDs: row.sourceRowIDs
        )
    }

    private func splitRow(old: DiffRowSnapshot?, new: DiffRowSnapshot?) -> DiffRowSnapshot {
        let id = old?.id ?? new?.id ?? "split-padding"
        let sourceIDs = [old?.id, new?.id].compactMap { $0 }.reduce(into: [String]()) { ids, candidate in
            if !ids.contains(candidate) { ids.append(candidate) }
        }
        return DiffRowSnapshot(
            id: id,
            kind: .context,
            text: "",
            splitOldSide: old.map { DiffSplitSideSnapshot(row: $0, usesOldNumber: true) },
            splitNewSide: new.map { DiffSplitSideSnapshot(row: $0, usesOldNumber: false) },
            sourceRowIDs: sourceIDs
        )
    }

    private func kind(_ kind: MobileChangesRowKind) -> DiffRowKind {
        switch kind {
        case .context, .unknown: .context
        case .add: .addition
        case .del: .deletion
        case .noNewline: .noNewline
        }
    }

    private func marker(_ kind: MobileChangesRowKind) -> String {
        switch kind {
        case .add: "+"
        case .del: "−"
        case .noNewline: "\\"
        case .context, .unknown: " "
        }
    }
}
