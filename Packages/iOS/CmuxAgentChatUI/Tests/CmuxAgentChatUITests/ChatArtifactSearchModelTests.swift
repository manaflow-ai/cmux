import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite("Artifact text search")
struct ChatArtifactSearchModelTests {
    @Test("literal case-insensitive search returns UTF-16 ranges")
    func findsLiteralRanges() {
        let model = ChatArtifactSearchModel(
            query: "A.B",
            text: "a.b A-B A.B a.b"
        )

        #expect(model.matchRanges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3),
            NSRange(location: 12, length: 3),
        ])
        #expect(model.summary == ChatArtifactSearchSummary(currentPosition: 1, matchCount: 3))
    }

    @Test("next and previous wrap around")
    func navigationWraps() {
        var model = ChatArtifactSearchModel(query: "hit", text: "hit no hit")

        model.selectPrevious()
        #expect(model.summary.currentPosition == 2)
        model.selectNext()
        #expect(model.summary.currentPosition == 1)
        model.selectNext()
        #expect(model.summary.currentPosition == 2)
        model.selectNext()
        #expect(model.summary.currentPosition == 1)
    }

    @Test("stream append recomputes matches and preserves selection")
    func recomputesAfterAppend() {
        var model = ChatArtifactSearchModel(query: "line", text: "line one\nline two")
        model.selectNext()
        let selectedRange = model.currentRange

        model.recompute(in: "line one\nline two\nLINE three")

        #expect(model.matchRanges.count == 3)
        #expect(model.currentRange == selectedRange)
        #expect(model.summary == ChatArtifactSearchSummary(currentPosition: 2, matchCount: 3))
    }
}
