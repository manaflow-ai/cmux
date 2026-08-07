import Foundation

/// Maps UTF-16 character offsets to logical one-based line numbers.
struct FilePreviewLineNumberIndex {
    private(set) var lineStarts: [Int]

    init(text: NSString) {
        lineStarts = Self.scanLineStarts(
            in: text,
            from: 0,
            to: text.length,
            includeTrailingLineStart: true
        )
    }

    init(text: String) {
        self.init(text: text as NSString)
    }

    var lineCount: Int {
        lineStarts.count
    }

    func lineNumber(atCharacterLocation location: Int) -> Int {
        max(1, upperBoundIndex(for: location))
    }

    func lineStart(forLineNumber lineNumber: Int) -> Int? {
        guard lineStarts.indices.contains(lineNumber - 1) else { return nil }
        return lineStarts[lineNumber - 1]
    }

    mutating func applyCharacterEdit(
        updatedRange: NSRange,
        changeInLength delta: Int,
        updatedText: NSString
    ) {
        let (originalLength, lengthOverflow) = updatedRange.length
            .subtractingReportingOverflow(delta)
        let (oldLength, oldLengthOverflow) = updatedText.length
            .subtractingReportingOverflow(delta)
        guard !lengthOverflow,
              !oldLengthOverflow,
              originalLength >= 0,
              oldLength >= 0,
              updatedRange.location != NSNotFound,
              updatedRange.location <= updatedText.length,
              updatedRange.length <= updatedText.length - updatedRange.location else {
            self = FilePreviewLineNumberIndex(text: updatedText)
            return
        }

        // NSTextStorage reports `editedRange` in the updated string when
        // `didProcessEditingNotification` fires. The splice below operates on
        // the cached pre-edit line starts, so recover the original range length
        // by removing the reported length delta.
        let originalRange = NSRange(
            location: updatedRange.location,
            length: originalLength
        )
        guard originalRange.location != NSNotFound,
              originalRange.location <= oldLength,
              originalRange.length <= oldLength - originalRange.location,
              lineStarts.first == 0,
              (lineStarts.last ?? 0) <= oldLength else {
            self = FilePreviewLineNumberIndex(text: updatedText)
            return
        }

        let oldEditEnd = originalRange.location + originalRange.length
        let containingLineIndex = max(
            0,
            upperBoundIndex(for: min(originalRange.location, oldLength)) - 1
        )
        // Include the preceding logical line so edits at CR/LF boundaries can
        // merge or split line endings without leaving a stale cached boundary.
        let scanLineIndex = max(0, containingLineIndex - 1)
        let scanStart = lineStarts[scanLineIndex]

        let firstLineAfterEdit = upperBoundIndex(for: oldEditEnd)
        let suffixLineIndex: Int
        if firstLineAfterEdit < lineStarts.count {
            // Rescan one complete unaffected line after the edit. This keeps
            // CRLF and paragraph-separator changes contained in the splice.
            suffixLineIndex = min(lineStarts.count, firstLineAfterEdit + 1)
        } else {
            suffixLineIndex = lineStarts.count
        }

        let oldScanEnd = suffixLineIndex < lineStarts.count
            ? lineStarts[suffixLineIndex]
            : oldLength
        let newScanEnd = oldScanEnd + delta
        guard scanStart <= newScanEnd, newScanEnd <= updatedText.length else {
            self = FilePreviewLineNumberIndex(text: updatedText)
            return
        }

        let rescannedStarts = Self.scanLineStarts(
            in: updatedText,
            from: scanStart,
            to: newScanEnd,
            includeTrailingLineStart: suffixLineIndex == lineStarts.count
        )

        var nextStarts = Array(lineStarts[..<scanLineIndex])
        nextStarts.reserveCapacity(
            nextStarts.count + rescannedStarts.count + (lineStarts.count - suffixLineIndex)
        )
        nextStarts.append(contentsOf: rescannedStarts)
        if suffixLineIndex < lineStarts.count {
            nextStarts.append(contentsOf: lineStarts[suffixLineIndex...].map { $0 + delta })
        }
        lineStarts = nextStarts
    }

    private func upperBoundIndex(for location: Int) -> Int {
        var lowerBound = 0
        var upperBound = lineStarts.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lineStarts[middle] <= location {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private static func scanLineStarts(
        in text: NSString,
        from start: Int,
        to upperBound: Int,
        includeTrailingLineStart: Bool
    ) -> [Int] {
        guard start <= upperBound else { return [0] }

        var starts = [start]
        var cursor = start
        while cursor < upperBound {
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: cursor, length: 0)
            )
            guard lineEnd > cursor else { break }

            if lineEnd < upperBound {
                starts.append(lineEnd)
            } else if lineEnd == upperBound,
                      includeTrailingLineStart,
                      contentsEnd < lineEnd {
                starts.append(lineEnd)
            }
            cursor = lineEnd
        }
        return starts
    }
}
