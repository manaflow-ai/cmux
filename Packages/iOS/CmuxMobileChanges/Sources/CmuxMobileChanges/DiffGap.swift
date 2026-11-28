/// One unchanged region omitted between the visible hunks of a file diff.
struct DiffGap: Sendable, Equatable, Identifiable {
    /// The gap's position relative to the document's hunks.
    enum Placement: Sendable, Equatable {
        case leading
        case inner
        case trailing
    }

    let id: Int
    let placement: Placement
    /// One-based new-file line numbers. `nil` means a trailing range awaiting EOF.
    let newLineRange: Range<Int>?
    /// Added to a new-file line number to obtain its old-file line number.
    let oldLineOffset: Int

    var directions: [DiffExpansionDirection] {
        switch placement {
        case .leading: [.up]
        case .inner: [.down, .up]
        case .trailing: [.down]
        }
    }

    func oldLineNumber(forNewLine newLine: Int) -> Int? {
        let oldLine = newLine + oldLineOffset
        return oldLine > 0 ? oldLine : nil
    }

    static func gaps(
        for document: FileDiffDocument,
        currentFileLineCount: Int?
    ) -> [DiffGap] {
        guard !document.hunks.isEmpty else { return [] }

        var gaps: [DiffGap] = []
        let first = document.hunks[0]
        let leadingUpperBound = first.newStart + (first.newCount == 0 ? 1 : 0)
        if leadingUpperBound > 1 {
            gaps.append(DiffGap(
                id: 0,
                placement: .leading,
                newLineRange: 1..<leadingUpperBound,
                oldLineOffset: first.oldStart - first.newStart
            ))
        }

        for nextIndex in document.hunks.indices.dropFirst() {
            let previous = document.hunks[nextIndex - 1]
            let next = document.hunks[nextIndex]
            let lowerBound = previous.newStart + max(previous.newCount, 1)
            let upperBound = next.newStart + (next.newCount == 0 ? 1 : 0)
            if lowerBound < upperBound {
                gaps.append(DiffGap(
                    id: nextIndex,
                    placement: .inner,
                    newLineRange: lowerBound..<upperBound,
                    oldLineOffset: next.oldStart - next.newStart
                ))
            }
        }

        let last = document.hunks[document.hunks.count - 1]
        let trailingLowerBound = last.newStart + max(last.newCount, 1)
        let trailingRange = currentFileLineCount.map { lineCount in
            trailingLowerBound..<max(trailingLowerBound, lineCount + 1)
        }
        if trailingRange == nil || trailingRange?.isEmpty == false {
            let oldBoundary = last.oldStart + max(last.oldCount, 1)
            gaps.append(DiffGap(
                id: document.hunks.count,
                placement: .trailing,
                newLineRange: trailingRange,
                oldLineOffset: oldBoundary - trailingLowerBound
            ))
        }
        return gaps
    }
}
