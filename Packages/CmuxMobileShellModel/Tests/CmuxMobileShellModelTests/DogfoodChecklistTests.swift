import Foundation
import Testing

@testable import CmuxMobileShellModel

/// Behavior tests for the dogfood checklist + answer DTOs: the JSON the agent
/// pushes via `dogfood_checklist_set` must decode into the typed model, and the
/// answers the pane submits must round-trip through JSON.
@Suite struct DogfoodChecklistTests {
    @Test func decodesPassFailAndChoiceItemsFromAgentJSON() throws {
        let json = Data(#"""
        {
          "title": "Floating pane test",
          "items": [
            {"id": "drag", "prompt": "Does the pill drag?", "kind": "pass_fail"},
            {"id": "edge", "prompt": "Which edge?", "kind": "choice", "choices": ["left", "right"]}
          ]
        }
        """#.utf8)

        let checklist = try DogfoodChecklist.decode(json)

        #expect(checklist.title == "Floating pane test")
        #expect(checklist.items.count == 2)
        #expect(checklist.items[0].id == "drag")
        #expect(checklist.items[0].kind == .passFail)
        #expect(checklist.items[0].choices == DogfoodChecklistItemKind.passFailChoices)
        #expect(checklist.items[1].kind == .choice(["left", "right"]))
        #expect(checklist.items[1].choices == ["left", "right"])
    }

    @Test func defaultsMissingKindToPassFail() throws {
        let json = Data(#"{"items":[{"id":"x","prompt":"No kind?"}]}"#.utf8)
        let checklist = try DogfoodChecklist.decode(json)
        #expect(checklist.title == nil)
        #expect(checklist.items.first?.kind == .passFail)
    }

    @Test func emptyChoiceListFallsBackToPassFail() throws {
        // A `choice` item with no usable choices is meaningless; it must stay
        // answerable rather than render a dead row.
        let json = Data(#"{"items":[{"id":"x","prompt":"Bad","kind":"choice","choices":[]}]}"#.utf8)
        let checklist = try DogfoodChecklist.decode(json)
        #expect(checklist.items.first?.kind == .passFail)
    }

    @Test func unknownKindFallsBackToPassFail() throws {
        let json = Data(#"{"items":[{"id":"x","prompt":"Future","kind":"slider"}]}"#.utf8)
        let checklist = try DogfoodChecklist.decode(json)
        #expect(checklist.items.first?.kind == .passFail)
    }

    @Test func checklistRoundTripsThroughEncodeDecode() throws {
        let checklist = DogfoodChecklist(
            title: "Round trip",
            items: [
                DogfoodChecklistItem(id: "a", prompt: "Pass/fail", kind: .passFail),
                DogfoodChecklistItem(id: "b", prompt: "Choice", kind: .choice(["one", "two", "three"])),
            ]
        )
        let decoded = try DogfoodChecklist.decode(checklist.encode())
        #expect(decoded == checklist)
    }

    @Test func clearPayloadsDecodeToAnEmptyChecklist() throws {
        // The Mac's clear path pushes `{"items":[]}`, and an agent may send `{}`.
        // Both must decode to an empty checklist (not throw) so the pane clears.
        #expect(try DogfoodChecklist.decode(Data("{}".utf8)).isEmpty)
        #expect(try DogfoodChecklist.decode(Data(#"{"items":[]}"#.utf8)).isEmpty)
    }

    @Test func emptyChecklistIsEmpty() {
        #expect(DogfoodChecklist.empty.isEmpty)
        #expect(DogfoodChecklist(items: []).isEmpty)
        #expect(!DogfoodChecklist(items: [DogfoodChecklistItem(id: "x", prompt: "y")]).isEmpty)
    }

    @Test func answersRoundTripWithNote() throws {
        let answers = DogfoodFeedbackAnswers(
            answers: [
                DogfoodFeedbackAnswer(id: "drag", choice: "pass"),
                DogfoodFeedbackAnswer(id: "edge", choice: "left"),
            ],
            note: "looked good overall"
        )
        let decoded = try DogfoodFeedbackAnswers.decode(answers.encode())
        #expect(decoded == answers)
        #expect(decoded.note == "looked good overall")
    }

    @Test func unansweredItemsAreOmittedFromAnswers() throws {
        // The pane built a checklist with three items but the dogfooder only
        // answered one; the omitted ids must simply be absent so the Mac can tell
        // answered from skipped.
        let answers = DogfoodFeedbackAnswers(
            answers: [DogfoodFeedbackAnswer(id: "i2", choice: "fail")],
            note: ""
        )
        let decoded = try DogfoodFeedbackAnswers.decode(answers.encode())
        #expect(decoded.answers.map(\.id) == ["i2"])
        #expect(decoded.note.isEmpty)
    }

    @Test func answersEncodeWithStableSortedKeys() throws {
        // Sorted-keys output keeps the bundle's `answers` JSON deterministic.
        let answers = DogfoodFeedbackAnswers(
            answers: [DogfoodFeedbackAnswer(id: "z", choice: "skip")],
            note: "n"
        )
        let string = String(decoding: try answers.encode(), as: UTF8.self)
        #expect(string == #"{"answers":[{"choice":"skip","id":"z"}],"note":"n"}"#)
    }
}
