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
    /// A whole-document replace degenerates to the full `init(string:)` scan,
    /// which is the only remaining O(n) path (initial load / wholesale set).
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
        let replacementUnits = replacement.utf16
        let replacementLength = replacementUnits.count
        let delta = replacementLength - oldLength
        let upperBound = location + oldLength

        var result: [Int] = []
        result.reserveCapacity(lineStartOffsets.count)
        for start in lineStartOffsets where start <= location {
            result.append(start)
        }
        var index = 0
        for unit in replacementUnits {
            if unit == 10 {
                result.append(location + index + 1)
            }
            index += 1
        }
        for start in lineStartOffsets where start > upperBound {
            result.append(start + delta)
        }
        lineStartOffsets = result
        loadedUTF16Length += delta
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
