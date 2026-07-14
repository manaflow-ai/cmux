/// Incremental UTF-16 line starts for streamed text and constant-time line jumps.
struct ChatArtifactLineIndex: Equatable, Sendable {
    private(set) var lineStartOffsets: [Int] = [0]
    private(set) var loadedUTF16Length = 0

    var lineCount: Int {
        lineStartOffsets.count
    }

    /// Adds line starts from one newly decoded streaming chunk.
    mutating func append(_ text: String) {
        let baseOffset = loadedUTF16Length
        var chunkOffset = 0
        for codeUnit in text.utf16 {
            chunkOffset += 1
            if codeUnit == 0x0A {
                lineStartOffsets.append(baseOffset + chunkOffset)
            }
        }
        loadedUTF16Length += chunkOffset
    }

    /// Clamps a one-based requested line to the range currently loaded.
    func clampedLine(_ requestedLine: Int) -> Int {
        min(max(requestedLine, 1), lineCount)
    }

    /// Returns the UTF-16 location for a one-based line, clamped to loaded lines.
    func offset(forLine requestedLine: Int) -> Int {
        lineStartOffsets[clampedLine(requestedLine) - 1]
    }

    /// Finds the one-based logical line containing a UTF-16 text location.
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
