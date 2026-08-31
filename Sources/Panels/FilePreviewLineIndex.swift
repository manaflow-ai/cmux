import Foundation

/// UTF-16 line starts for a fully loaded File Preview buffer.
struct FilePreviewLineIndex: Equatable, Sendable {
    private(set) var lineStartOffsets: [Int]
    private(set) var loadedUTF16Length: Int

    var lineCount: Int {
        lineStartOffsets.count
    }

    init(string: String) {
        // Native UTF-16 iteration, not `NSString.character(at:)` message sends:
        // initial builds scan File Preview buffers up to 16 MB.
        var offsets = [0]
        var index = 0
        for unit in string.utf16 {
            if unit == 10 {
                offsets.append(index + 1)
            }
            index += 1
        }
        lineStartOffsets = offsets
        loadedUTF16Length = index
    }

    /// Applies one text-storage edit incrementally instead of rescanning the
    /// whole buffer.
    ///
    /// Line starts at or before `location` are untouched, starts inside the
    /// replaced range are dropped and re-derived from `replacement`, and every
    /// start after the replaced range shifts by the edit's net length delta.
    /// The splice happens in place — the untouched prefix is never revisited
    /// and no replacement array is allocated — so typing at the end of a
    /// document costs O(edit), not O(lines). A whole-document replace
    /// degenerates to shifting the entire (single-line-start) tail, and the
    /// full `init(string:)` scan remains the only O(buffer) path (initial
    /// load / wholesale set).
    ///
    /// - Parameters:
    ///   - location: post-edit UTF-16 offset where the replacement begins.
    ///   - oldLength: UTF-16 length of the range that was replaced.
    ///   - replacement: the text now occupying the edited range.
    mutating func applyEdit(
        atUTF16Location location: Int,
        replacingUTF16Length oldLength: Int,
        replacement: String
    ) {
        let replacementLength = replacement.utf16.count
        let delta = replacementLength - oldLength
        let upperBound = location + oldLength

        // Offsets are strictly increasing, so both boundaries are binary
        // searches: starts in [0, lowerBound) survive untouched; starts in
        // [lowerBound, upperStart) came from the replaced text and are
        // dropped; starts in [upperStart, ...) shift by the delta in place.
        let lowerBound = Self.firstIndex(afterOffset: location, in: lineStartOffsets)
        let upperStart = Self.firstIndex(afterOffset: upperBound, in: lineStartOffsets)

        if delta != 0 {
            for index in upperStart..<lineStartOffsets.count {
                lineStartOffsets[index] += delta
            }
        }
        lineStartOffsets.removeSubrange(lowerBound..<upperStart)

        var insertedStarts: [Int] = []
        var index = 0
        for unit in replacement.utf16 {
            if unit == 10 {
                insertedStarts.append(location + index + 1)
            }
            index += 1
        }
        if !insertedStarts.isEmpty {
            lineStartOffsets.insert(contentsOf: insertedStarts, at: lowerBound)
        }
        loadedUTF16Length += delta
    }

    /// Index of the first offset strictly greater than `offset`.
    private static func firstIndex(afterOffset offset: Int, in offsets: [Int]) -> Int {
        var lower = 0
        var upper = offsets.count
        while lower < upper {
            let midpoint = (lower + upper) / 2
            if offsets[midpoint] <= offset {
                lower = midpoint + 1
            } else {
                upper = midpoint
            }
        }
        return lower
    }

    func offset(forLine requestedLine: Int) -> Int {
        let clamped = min(max(requestedLine, 1), lineCount)
        return lineStartOffsets[clamped - 1]
    }

    func lineNumber(containingUTF16Offset requestedOffset: Int) -> Int {
        let offset = min(max(requestedOffset, 0), loadedUTF16Length)
        var lowerBound = 0
        var upperBound = lineStartOffsets.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if lineStartOffsets[midpoint] <= offset {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return max(lowerBound, 1)
    }
}
