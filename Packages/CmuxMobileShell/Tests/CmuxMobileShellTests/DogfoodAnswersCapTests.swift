#if DEBUG
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for the answers-JSON byte cap used when building a dogfood
/// feedback submit: an oversized note must never silently discard the structured
/// multiple-choice answers (the dogfooder's actual responses).
@Suite struct DogfoodAnswersCapTests {
    @Test func smallAnswersPassThroughUnchanged() throws {
        let answers = DogfoodFeedbackAnswers(
            answers: [DogfoodFeedbackAnswer(id: "a", choice: "pass")],
            note: "ok"
        )
        let json = try answers.encode()
        let capped = MobileShellComposite.cappedAnswersJSONString(json, maxBytes: 65_536)
        #expect(capped == String(data: json, encoding: .utf8))
    }

    @Test func oversizedNoteIsDroppedButMCAnswersSurvive() throws {
        // A huge note pushes the encoded payload over the cap; the structured MC
        // answers must survive (note dropped, not the answers).
        let bigNote = String(repeating: "x", count: 200_000)
        let answers = DogfoodFeedbackAnswers(
            answers: [
                DogfoodFeedbackAnswer(id: "a", choice: "pass"),
                DogfoodFeedbackAnswer(id: "b", choice: "fail"),
            ],
            note: bigNote
        )
        let json = try answers.encode()
        let cappedString = try #require(
            MobileShellComposite.cappedAnswersJSONString(json, maxBytes: 4_096)
        )
        let cappedData = try #require(cappedString.data(using: .utf8))
        #expect(cappedData.count <= 4_096)
        let decoded = try DogfoodFeedbackAnswers.decode(cappedData)
        // The MC answers are preserved; only the note was dropped.
        #expect(decoded.answers.map(\.id) == ["a", "b"])
        #expect(decoded.note.isEmpty)
    }

    @Test func nilAnswersReturnNil() {
        #expect(MobileShellComposite.cappedAnswersJSONString(nil, maxBytes: 65_536) == nil)
    }
}
#endif
