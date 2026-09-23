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

    /// Creates a diff with the default budgets of 20,000 lines and 2 MiB.
    ///
    /// The line diff costs time proportional to the line count times the
    /// number of edits, so the budgets make an unusually large file cost
    /// nothing instead of stalling a core.
    public init() {
        self.init(maximumLineCount: 20_000, maximumByteCount: 2 * 1024 * 1024)
    }

    init(maximumLineCount: Int, maximumByteCount: Int) {
        self.maximumLineCount = maximumLineCount
        self.maximumByteCount = maximumByteCount
    }

    /// Returns the changed lines of `current` relative to `base`.
    ///
    /// The line diff costs time proportional to the line count times the
    /// number of edits, so call it off the main actor.
    ///
    /// - Parameters:
    ///   - base: The git base content, usually the file at HEAD.
    ///   - current: The live buffer content.
    /// - Returns: Changes keyed by 1-based line number in `current`. Empty
    ///   when the texts match or either side exceeds a budget.
    public func changes(
        base: String,
        current: String
    ) -> [Int: FilePreviewGitLineChange] {
        guard base.utf8.count <= maximumByteCount,
              current.utf8.count <= maximumByteCount else { return [:] }
        let baseLines = Self.lines(of: base)
        let currentLines = Self.lines(of: current)
        guard baseLines.count <= maximumLineCount,
              currentLines.count <= maximumLineCount else { return [:] }
        guard baseLines != currentLines else { return [:] }

        var removedBaseOffsets: Set<Int> = []
        var insertedCurrentOffsets: Set<Int> = []
        for change in currentLines.difference(from: baseLines) {
            switch change {
            case let .remove(offset, _, _):
                removedBaseOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedCurrentOffsets.insert(offset)
            }
        }
        var accumulator = FilePreviewGitLineChangeAccumulator(currentLineCount: currentLines.count)
        var baseIndex = 0
        var currentIndex = 0
        // Removal offsets index the base and insertion offsets index the
        // current buffer, so both must be consumed in the same walk.
        while baseIndex < baseLines.count || currentIndex < currentLines.count {
            if baseIndex < baseLines.count, removedBaseOffsets.contains(baseIndex) {
                accumulator.recordRemoval()
                baseIndex += 1
            } else if currentIndex < currentLines.count,
                      insertedCurrentOffsets.contains(currentIndex) {
                accumulator.recordInsertion(atOffset: currentIndex)
                currentIndex += 1
            } else {
                accumulator.closeRun(beforeOffset: currentIndex)
                baseIndex += 1
                currentIndex += 1
            }
        }
        accumulator.closeRun(beforeOffset: currentIndex)
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
