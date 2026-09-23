import Foundation

/// The git change painted beside one gutter line.
public enum FilePreviewGitLineChange: Sendable, Equatable {
    case added // Line absent from the base.
    case modified // Line that replaced base lines.
    case removed // Base lines were deleted just above this line.
    case removedAtEnd // Base lines were deleted below this last line.
}

/// Line-level comparison between the working buffer and its git base.
///
/// - Result keys are 1-based line numbers in the current buffer.
/// - Deletions have no line of their own, so they attach to a surviving neighbor.
/// - A run that both inserts and deletes is reported as modified.
/// - Inputs over the budgets produce no markers.
public enum FilePreviewGitLineDiff {
    /// Line count above which diffing is skipped.
    public static let maximumLineCount = 20_000
    /// UTF-8 byte count above which diffing is skipped.
    public static let maximumByteCount = 2 * 1024 * 1024

    /// Returns the changed lines of `current` relative to `base`.
    ///
    /// Call off the main thread.
    public static func changes(
        base: String,
        current: String
    ) -> [Int: FilePreviewGitLineChange] {
        guard base.utf8.count <= maximumByteCount,
              current.utf8.count <= maximumByteCount else { return [:] }
        let baseLines = lines(of: base)
        let currentLines = lines(of: current)
        guard baseLines.count <= maximumLineCount,
              currentLines.count <= maximumLineCount else { return [:] }
        guard baseLines != currentLines else { return [:] }

        let difference = currentLines.difference(from: baseLines)
        var removedBaseOffsets: Set<Int> = []
        var insertedCurrentOffsets: Set<Int> = []
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedBaseOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedCurrentOffsets.insert(offset)
            }
        }
        return markers(
            baseLineCount: baseLines.count,
            currentLineCount: currentLines.count,
            removedBaseOffsets: removedBaseOffsets,
            insertedCurrentOffsets: insertedCurrentOffsets
        )
    }

    /// Walks both sequences in step and marks each change run.
    ///
    /// Removal offsets index the base and insertion offsets index the current
    /// buffer, so both must be consumed in the same walk to stay aligned.
    private static func markers(
        baseLineCount: Int,
        currentLineCount: Int,
        removedBaseOffsets: Set<Int>,
        insertedCurrentOffsets: Set<Int>
    ) -> [Int: FilePreviewGitLineChange] {
        var result: [Int: FilePreviewGitLineChange] = [:]
        var baseIndex = 0
        var currentIndex = 0
        var runRemovalCount = 0
        var runInsertedLines: [Int] = []

        while baseIndex < baseLineCount || currentIndex < currentLineCount {
            if baseIndex < baseLineCount, removedBaseOffsets.contains(baseIndex) {
                runRemovalCount += 1
                baseIndex += 1
                continue
            }
            if currentIndex < currentLineCount, insertedCurrentOffsets.contains(currentIndex) {
                runInsertedLines.append(currentIndex)
                currentIndex += 1
                continue
            }
            flush(
                removalCount: runRemovalCount,
                insertedLines: runInsertedLines,
                anchorLine: currentIndex,
                currentLineCount: currentLineCount,
                into: &result
            )
            runRemovalCount = 0
            runInsertedLines.removeAll(keepingCapacity: true)
            baseIndex += 1
            currentIndex += 1
        }
        flush(
            removalCount: runRemovalCount,
            insertedLines: runInsertedLines,
            anchorLine: currentIndex,
            currentLineCount: currentLineCount,
            into: &result
        )
        return result
    }

    /// Converts one change run into markers.
    ///
    /// - Insertions only: every inserted line is added.
    /// - Insertions and removals: every inserted line is modified.
    /// - Removals only: the following line is marked removed.
    /// - Removals at the end: the last line is marked removedAtEnd.
    private static func flush(
        removalCount: Int,
        insertedLines: [Int],
        anchorLine: Int,
        currentLineCount: Int,
        into result: inout [Int: FilePreviewGitLineChange]
    ) {
        guard removalCount > 0 || !insertedLines.isEmpty else { return }
        if !insertedLines.isEmpty {
            let kind: FilePreviewGitLineChange = removalCount > 0 ? .modified : .added
            for line in insertedLines {
                result[line + 1] = kind
            }
            return
        }
        if anchorLine < currentLineCount {
            result[anchorLine + 1] = .removed
        } else if currentLineCount > 0 {
            result[currentLineCount] = .removedAtEnd
        }
    }

    /// Splits text into lines.
    ///
    /// Drops the empty tail after a final newline to match git's line count,
    /// and strips CR so CRLF versus LF does not read as a change.
    private static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        if result.last == "" {
            result.removeLast()
        }
        return result.map { line in
            line.hasSuffix("\r") ? String(line.dropLast()) : line
        }
    }
}
