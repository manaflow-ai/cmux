/// Precomputed line-index contribution for one streamed text chunk.
struct ChatArtifactLineIndexBatch: Equatable, Sendable {
    let utf16Length: Int
    let relativeLineStartOffsets: [Int]

    init(text: String) {
        var utf16Length = 0
        var lineStartOffsets: [Int] = []
        for codeUnit in text.utf16 {
            utf16Length += 1
            if codeUnit == 0x0A {
                lineStartOffsets.append(utf16Length)
            }
        }
        self.utf16Length = utf16Length
        relativeLineStartOffsets = lineStartOffsets
    }
}
