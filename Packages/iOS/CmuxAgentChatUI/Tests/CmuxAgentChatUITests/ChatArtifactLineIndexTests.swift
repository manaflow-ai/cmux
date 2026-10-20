import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact line index")
struct ChatArtifactLineIndexTests {
    @Test("line starts accumulate incrementally in UTF-16 offsets")
    func appendsLineStarts() {
        var index = ChatArtifactLineIndex()

        index.append("one\n🙂")
        #expect(index.lineStartOffsets == [0, 4])
        #expect(index.loadedUTF16Length == 6)
        index.append("\nthree\n")

        #expect(index.lineStartOffsets == [0, 4, 7, 13])
        #expect(index.loadedUTF16Length == 13)
        #expect(index.lineCount == 4)
        #expect(index.lineNumber(containingUTF16Offset: 8) == 3)
    }

    @Test("go to line clamps against lines loaded so far")
    func clampsDuringStreaming() {
        var index = ChatArtifactLineIndex()
        index.append("first\nsecond")

        #expect(index.clampedLine(-4) == 1)
        #expect(index.offset(forLine: -4) == 0)
        #expect(index.clampedLine(200) == 2)
        #expect(index.offset(forLine: 200) == 6)

        index.append("\nthird")
        #expect(index.clampedLine(3) == 3)
        #expect(index.offset(forLine: 3) == 13)
    }
}
