import Foundation

/// Compares a working buffer with its git base, line by line.
///
/// Lines split on the same breaks the gutter's ``FilePreviewLineIndex`` counts
/// (LF, CR, CRLF, U+2028, and U+2029), so every marker lands on the line the
/// gutter numbers. A break style difference alone, such as CRLF versus LF, is
/// not a change.
///
/// Deletions have no line of their own, so they attach to the surviving line
/// that follows them, or to the last line when they end the file. A run that
/// both inserts and deletes lines is reported as modified.
///
/// Lines shared at the start and end are trimmed first, so an ordinary edit
/// costs linear time. Only the differing middle is aligned, and a middle
/// larger than the alignment budget, such as a formatter rewriting the whole
/// file, is reported as a single modified run instead of being aligned.
///
/// ```swift
/// let diff = FilePreviewGitLineDiff()
/// let changes = diff.changes(base: "one\ntwo\n", current: "one\nTWO\n")
/// // [2: .modified]
/// ```
public struct FilePreviewGitLineDiff: Sendable {
    /// Line count, on either side, above which diffing is skipped.
    let maximumLineCount: Int
    /// UTF-8 size, on either side, above which diffing is skipped.
    let maximumByteCount: Int
    /// Differing middle size, on either side, above which lines are not
    /// aligned one by one.
    let maximumAlignedLineCount: Int

    /// Creates a diff with the default budgets: 20,000 lines, 2 MiB, and
    /// 2,000 aligned lines.
    ///
    /// Aligning costs time proportional to the middle's size times its edit
    /// count, so the alignment budget keeps the worst case near a tenth of a
    /// second instead of several seconds for a fully rewritten large file.
    public init() {
        self.init(maximumLineCount: 20_000, maximumByteCount: 2 * 1024 * 1024)
    }

    /// Creates a diff with explicit budgets, so tests can reach each budget
    /// with small inputs.
    init(maximumLineCount: Int, maximumByteCount: Int, maximumAlignedLineCount: Int = 2_000) {
        self.maximumLineCount = maximumLineCount
        self.maximumByteCount = maximumByteCount
        self.maximumAlignedLineCount = maximumAlignedLineCount
    }

    /// Returns the changed lines of `current` relative to `base`.
    ///
    /// Splitting and trimming scan both texts, so call it off the main actor.
    /// Each stage checks for cancellation of the calling task, so a caller
    /// that stops caring does not pay for the rest of the diff.
    ///
    /// - Parameters:
    ///   - base: The git base content, usually the file at HEAD.
    ///   - current: The live buffer content.
    /// - Returns: Changes keyed by 1-based line number in `current`. Empty
    ///   when the texts match, either side exceeds a budget, or the calling
    ///   task is cancelled.
    public func changes(
        base: String,
        current: String
    ) -> [Int: FilePreviewGitLineChange] {
        guard base.utf8.count <= maximumByteCount,
              current.utf8.count <= maximumByteCount else { return [:] }
        let baseLines = Self.lines(of: base)
        guard !Task.isCancelled else { return [:] }
        let currentLines = Self.lines(of: current)
        guard !Task.isCancelled else { return [:] }
        guard baseLines.count <= maximumLineCount,
              currentLines.count <= maximumLineCount else { return [:] }
        guard baseLines != currentLines else { return [:] }

        var prefix = 0
        let shorter = min(baseLines.count, currentLines.count)
        while prefix < shorter, baseLines[prefix] == currentLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < shorter - prefix,
              baseLines[baseLines.count - 1 - suffix] == currentLines[currentLines.count - 1 - suffix] {
            suffix += 1
        }
        let baseMiddle = Array(baseLines[prefix..<(baseLines.count - suffix)])
        let currentMiddle = Array(currentLines[prefix..<(currentLines.count - suffix)])
        guard !Task.isCancelled else { return [:] }

        var accumulator = FilePreviewGitLineChangeAccumulator(currentLineCount: currentLines.count)
        guard baseMiddle.count <= maximumAlignedLineCount,
              currentMiddle.count <= maximumAlignedLineCount else {
            accumulator.recordRemovals(baseMiddle.count)
            for offset in currentMiddle.indices {
                accumulator.recordInsertion(atOffset: prefix + offset)
            }
            accumulator.closeRun(beforeOffset: prefix + currentMiddle.count)
            return accumulator.changes
        }

        var removedBaseOffsets: Set<Int> = []
        var insertedCurrentOffsets: Set<Int> = []
        let difference = currentMiddle.difference(from: baseMiddle)
        guard !Task.isCancelled else { return [:] }
        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedBaseOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedCurrentOffsets.insert(offset)
            }
        }
        var baseIndex = 0
        var currentIndex = 0
        // Removal offsets index the base and insertion offsets index the
        // current buffer, so both must be consumed in the same walk.
        while baseIndex < baseMiddle.count || currentIndex < currentMiddle.count {
            if baseIndex < baseMiddle.count, removedBaseOffsets.contains(baseIndex) {
                accumulator.recordRemovals()
                baseIndex += 1
            } else if currentIndex < currentMiddle.count,
                      insertedCurrentOffsets.contains(currentIndex) {
                accumulator.recordInsertion(atOffset: prefix + currentIndex)
                currentIndex += 1
            } else {
                accumulator.closeRun(beforeOffset: prefix + currentIndex)
                baseIndex += 1
                currentIndex += 1
            }
        }
        accumulator.closeRun(beforeOffset: prefix + currentMiddle.count)
        return accumulator.changes
    }

    /// Splits `text` at every break the gutter counts, dropping the breaks.
    ///
    /// A trailing break does not produce an empty final line, matching how
    /// git counts lines. Breaks are single BMP code units, so slicing at their
    /// offsets never splits a surrogate pair.
    static func lines(of text: String) -> [String] {
        let units = Array(text.utf16)
        var result: [String] = []
        var lineStart = 0
        for lineBreak in FilePreviewLineIndexStorage.lineBreaks(in: text) {
            result.append(String(decoding: units[lineStart..<lineBreak.offset], as: UTF16.self))
            lineStart = lineBreak.offset + lineBreak.kind.length
        }
        if lineStart < units.count {
            result.append(String(decoding: units[lineStart...], as: UTF16.self))
        }
        return result
    }
}
