import Testing

@testable import CmuxAgentChatUI

struct ChatProseSegmenterTests {
    private let segmenter = ChatProseSegmenter()

    @Test func plainTextIsOneTextSegment() {
        let segments = segmenter.segments(from: "Just a sentence.\nAnd another.")
        #expect(segments.count == 1)
        #expect(segments[0].kind == .text)
        #expect(segments[0].content == "Just a sentence.\nAnd another.")
    }

    @Test func singleFenceSplitsTextCodeText() {
        let input = "Before\n```\nlet x = 1\n```\nAfter"
        let segments = segmenter.segments(from: input)
        #expect(segments.count == 3)
        #expect(segments[0].kind == .text)
        #expect(segments[0].content == "Before")
        #expect(segments[1].kind == .code(language: nil))
        #expect(segments[1].content == "let x = 1")
        #expect(segments[2].kind == .text)
        #expect(segments[2].content == "After")
    }

    @Test func fenceWithLanguageTagCarriesLanguage() {
        let input = "```swift\nprint(\"hi\")\n```"
        let segments = segmenter.segments(from: input)
        #expect(segments.count == 1)
        #expect(segments[0].kind == .code(language: "swift"))
        #expect(segments[0].content == "print(\"hi\")")
    }

    @Test func unterminatedFenceSwallowsRestAsCode() {
        let input = "Intro\n```sh\necho streaming"
        let segments = segmenter.segments(from: input)
        #expect(segments.count == 2)
        #expect(segments[0].kind == .text)
        #expect(segments[0].content == "Intro")
        #expect(segments[1].kind == .code(language: "sh"))
        #expect(segments[1].content == "echo streaming")
    }

    @Test func multipleFencesAlternate() {
        let input = "a\n```\none\n```\nb\n```py\ntwo\n```\nc"
        let segments = segmenter.segments(from: input)
        #expect(segments.count == 5)
        #expect(segments.map(\.kind) == [
            .text, .code(language: nil), .text, .code(language: "py"), .text,
        ])
        #expect(segments.map(\.id) == [0, 1, 2, 3, 4])
        #expect(segments[3].content == "two")
    }

    @Test func emptyFenceProducesAnEmptyCodeSegment() {
        // A fence the agent just opened (streaming) renders as an empty
        // code box rather than vanishing — intentional feedback.
        let segments = segmenter.segments(from: "```")
        #expect(segments.count == 1)
        #expect(segments[0].kind == .code(language: nil))
        #expect(segments[0].content.isEmpty)
    }

    @Test func languageTaggedFenceWithNoBodyKeepsLanguage() {
        let segments = segmenter.segments(from: "```swift\n```")
        #expect(segments.count == 1)
        #expect(segments[0].kind == .code(language: "swift"))
        #expect(segments[0].content.isEmpty)
    }

    @Test func textAfterAClosedFenceIsItsOwnSegment() {
        let segments = segmenter.segments(from: "```\ncode\n```\nafter")
        #expect(segments.map(\.kind) == [.code(language: nil), .text])
        #expect(segments[1].content == "after")
    }
}
