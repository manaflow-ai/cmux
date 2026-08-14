import Foundation

/// UTF-16 line starts for a fully loaded File Preview buffer.
struct FilePreviewLineIndex: Equatable, Sendable {
    private(set) var lineStartOffsets: [Int]
    private(set) var loadedUTF16Length: Int

    var lineCount: Int {
        lineStartOffsets.count
    }

    init(string: String) {
        let nsString = string as NSString
        var offsets = [0]
        let length = nsString.length
        var index = 0
        while index < length {
            if nsString.character(at: index) == 10 {
                offsets.append(index + 1)
            }
            index += 1
        }
        lineStartOffsets = offsets
        loadedUTF16Length = length
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
