/// Collects the removals and insertions of one change run and converts each
/// finished run into gutter markers.
///
/// A run is the stretch of removals and insertions between two unchanged
/// lines. ``FilePreviewGitLineDiff`` feeds it in document order.
struct FilePreviewGitLineChangeAccumulator {
    private let currentLineCount: Int
    private var removalCount = 0
    private var insertedLines: [Int] = []
    private(set) var changes: [Int: FilePreviewGitLineChange] = [:]

    init(currentLineCount: Int) {
        self.currentLineCount = currentLineCount
    }

    mutating func recordRemovals(_ count: Int = 1) {
        removalCount += count
    }

    /// Records an inserted line by its 0-based offset in the current buffer.
    mutating func recordInsertion(atOffset offset: Int) {
        insertedLines.append(offset)
    }

    /// Ends the open run at the unchanged line `anchorOffset`, which may be
    /// one past the last line.
    ///
    /// - Insertions only mark every inserted line added.
    /// - Insertions with removals mark every inserted line modified.
    /// - Removals only mark the anchor line removed, or the last line
    ///   removedAtEnd when the run ends the file.
    /// - Removals that leave the buffer empty mark line 1 removed, because
    ///   the gutter still numbers the empty document's single line.
    mutating func closeRun(beforeOffset anchorOffset: Int) {
        defer {
            removalCount = 0
            insertedLines.removeAll(keepingCapacity: true)
        }
        if !insertedLines.isEmpty {
            let kind: FilePreviewGitLineChange = removalCount > 0 ? .modified : .added
            for offset in insertedLines {
                changes[offset + 1] = kind
            }
        } else if removalCount > 0 {
            if anchorOffset < currentLineCount {
                changes[anchorOffset + 1] = .removed
            } else if currentLineCount > 0 {
                changes[currentLineCount] = .removedAtEnd
            } else {
                changes[1] = .removed
            }
        }
    }
}
