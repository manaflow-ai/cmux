#if DEBUG
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for ``DogfoodFeedbackModel`` (the floating DEV dogfood pane
/// model) with a fake submitter so the model is exercised without a live
/// connection: checklist application, answer selection, the ordered answers
/// payload, and the capture/submit reset behavior.
@MainActor
@Suite struct DogfoodFeedbackModelTests {
    /// Records the answers a capture submits and returns a scripted result.
    private final class FakeSubmitter: DogfoodFeedbackSubmitting {
        var result = true
        private(set) var submitted: [DogfoodFeedbackAnswers] = []
        func submit(answers: DogfoodFeedbackAnswers) async -> Bool {
            submitted.append(answers)
            return result
        }
    }

    private func makeChecklist() -> DogfoodChecklist {
        DogfoodChecklist(
            title: "Pane",
            items: [
                DogfoodChecklistItem(id: "a", prompt: "Pass/fail?", kind: .passFail),
                DogfoodChecklistItem(id: "b", prompt: "Choice?", kind: .choice(["x", "y"])),
            ]
        )
    }

    @Test func appliesAChecklistAndStartsUnanswered() {
        let model = DogfoodFeedbackModel(submitter: FakeSubmitter())
        model.applyChecklist(makeChecklist())
        #expect(model.checklist.items.count == 2)
        #expect(model.selection(for: "a") == nil)
        #expect(model.selection(for: "b") == nil)
    }

    @Test func selectingAndReselectingTogglesTheAnswer() {
        let model = DogfoodFeedbackModel(submitter: FakeSubmitter())
        model.applyChecklist(makeChecklist())
        model.selectAnswer(itemID: "a", choice: "pass")
        #expect(model.selection(for: "a") == "pass")
        // Reselecting the same choice clears it (un-answer back to skipped).
        model.selectAnswer(itemID: "a", choice: "pass")
        #expect(model.selection(for: "a") == nil)
        // Selecting a different choice replaces it.
        model.selectAnswer(itemID: "a", choice: "fail")
        model.selectAnswer(itemID: "a", choice: "pass")
        #expect(model.selection(for: "a") == "pass")
    }

    @Test func answersPayloadIsInChecklistOrderAndOmitsUnanswered() {
        let model = DogfoodFeedbackModel(submitter: FakeSubmitter())
        model.applyChecklist(makeChecklist())
        // Answer the second item first; payload must still read in checklist order
        // (b is index 1) and omit the unanswered first item.
        model.selectAnswer(itemID: "b", choice: "y")
        model.note = "note text"
        let payload = model.answersPayload
        #expect(payload.answers.map(\.id) == ["b"])
        #expect(payload.answers.first?.choice == "y")
        #expect(payload.note == "note text")

        model.selectAnswer(itemID: "a", choice: "pass")
        #expect(model.answersPayload.answers.map(\.id) == ["a", "b"])
    }

    @Test func applyingANewChecklistDropsStaleSelectionsButKeepsLiveOnes() {
        let model = DogfoodFeedbackModel(submitter: FakeSubmitter())
        model.applyChecklist(makeChecklist())
        model.selectAnswer(itemID: "a", choice: "pass")
        model.selectAnswer(itemID: "b", choice: "x")
        // Re-push a checklist that keeps "a" but drops "b" and adds "c".
        model.applyChecklist(DogfoodChecklist(items: [
            DogfoodChecklistItem(id: "a", prompt: "Pass/fail?", kind: .passFail),
            DogfoodChecklistItem(id: "c", prompt: "New", kind: .passFail),
        ]))
        #expect(model.selection(for: "a") == "pass")
        #expect(model.selection(for: "b") == nil)
        #expect(model.selection(for: "c") == nil)
    }

    @Test func rePushDropsAnswerWhoseChoiceIsNoLongerValid() {
        let model = DogfoodFeedbackModel(submitter: FakeSubmitter())
        model.applyChecklist(makeChecklist())
        model.selectAnswer(itemID: "b", choice: "x")
        #expect(model.selection(for: "b") == "x")
        // Re-push keeps id "b" but changes its choices so "x" is gone. The stale
        // selection must be dropped so it can't be submitted invisibly.
        model.applyChecklist(DogfoodChecklist(items: [
            DogfoodChecklistItem(id: "b", prompt: "Choice?", kind: .choice(["p", "q"])),
        ]))
        #expect(model.selection(for: "b") == nil)
        #expect(model.answersPayload.answers.isEmpty)
    }

    @Test func applyingAMalformedPayloadIsANoOp() {
        let model = DogfoodFeedbackModel(submitter: FakeSubmitter())
        model.applyChecklist(makeChecklist())
        model.applyChecklistPayload(Data("not json".utf8))
        model.applyChecklistPayload(nil)
        // Unchanged.
        #expect(model.checklist.items.count == 2)
    }

    @Test func captureSendsTheAnswersAndClearsOnSuccess() async {
        let submitter = FakeSubmitter()
        let model = DogfoodFeedbackModel(submitter: submitter)
        model.applyChecklist(makeChecklist())
        model.selectAnswer(itemID: "a", choice: "pass")
        model.note = "looks good"
        await model.captureAndSend()
        #expect(submitter.submitted.count == 1)
        #expect(submitter.submitted.first?.answers.map(\.id) == ["a"])
        #expect(submitter.submitted.first?.note == "looks good")
        #expect(model.lastSubmitSucceeded == true)
        // Success clears answers + note; the checklist stays for the next capture.
        #expect(model.selection(for: "a") == nil)
        #expect(model.note.isEmpty)
        #expect(model.checklist.items.count == 2)
    }

    @Test func applyingAChecklistWithDuplicateIDsDoesNotCrash() {
        // An agent can push a malformed checklist with repeated ids; the contract
        // is to ignore bad payloads, not trap on a duplicate-key dictionary build.
        let model = DogfoodFeedbackModel(submitter: FakeSubmitter())
        model.applyChecklist(DogfoodChecklist(items: [
            DogfoodChecklistItem(id: "dup", prompt: "First", kind: .choice(["a"])),
            DogfoodChecklistItem(id: "dup", prompt: "Second", kind: .choice(["b"])),
        ]))
        // The unioned valid set keeps a selection that matches either item's choices.
        model.selectAnswer(itemID: "dup", choice: "a")
        #expect(model.selection(for: "dup") == "a")
    }

    @Test func captureDoesNotCrashOnDuplicateChecklistIDs() async {
        // answersPayload emits one answer per row, so duplicate ids must not trap
        // when the success-path snapshot is built on Capture & Send.
        let model = DogfoodFeedbackModel(submitter: FakeSubmitter())
        model.applyChecklist(DogfoodChecklist(items: [
            DogfoodChecklistItem(id: "dup", prompt: "First", kind: .choice(["a"])),
            DogfoodChecklistItem(id: "dup", prompt: "Second", kind: .choice(["a"])),
        ]))
        model.selectAnswer(itemID: "dup", choice: "a")
        await model.captureAndSend()
        #expect(model.lastSubmitSucceeded == true)
    }

    /// Mutates the model during the submit await so the in-flight-edit path runs.
    private final class MutatingSubmitter: DogfoodFeedbackSubmitting {
        var onSubmit: (() -> Void)?
        func submit(answers: DogfoodFeedbackAnswers) async -> Bool {
            onSubmit?()
            return true
        }
    }

    @Test func captureKeepsInFlightEditsOnSuccess() async {
        let submitter = MutatingSubmitter()
        let model = DogfoodFeedbackModel(submitter: submitter)
        model.applyChecklist(makeChecklist())
        model.selectAnswer(itemID: "a", choice: "pass")
        model.note = "original"
        // While the submit is in flight, the dogfooder re-answers "a" and edits
        // the note. The success clear must preserve both.
        submitter.onSubmit = {
            model.selectAnswer(itemID: "a", choice: "fail")
            model.note = "edited mid-flight"
        }
        await model.captureAndSend()
        #expect(model.selection(for: "a") == "fail")
        #expect(model.note == "edited mid-flight")
    }

    @Test func captureKeepsAnswersOnFailure() async {
        let submitter = FakeSubmitter()
        submitter.result = false
        let model = DogfoodFeedbackModel(submitter: submitter)
        model.applyChecklist(makeChecklist())
        model.selectAnswer(itemID: "a", choice: "fail")
        model.note = "broken"
        await model.captureAndSend()
        #expect(model.lastSubmitSucceeded == false)
        // A failed submit keeps the answers so the dogfooder can retry.
        #expect(model.selection(for: "a") == "fail")
        #expect(model.note == "broken")
    }

    @Test func answersPayloadCapsAVeryLargeNote() {
        let model = DogfoodFeedbackModel(submitter: FakeSubmitter())
        model.note = String(repeating: "x", count: DogfoodFeedbackModel.maxNoteChars + 5_000)
        #expect(model.answersPayload.note.count == DogfoodFeedbackModel.maxNoteChars)
    }

    @Test func bothClearRoutesAgreeAndDropSelections() {
        // The Mac clears two ways: the event push sends `{"items":[]}` (decoded by
        // applyChecklistPayload) and the fetch-clear path calls applyChecklist(.empty).
        // Both must leave the same empty, selection-free model state so a live
        // reconnect after a clear does not strand a stale checklist/answer.
        let pushModel = DogfoodFeedbackModel(submitter: FakeSubmitter())
        pushModel.applyChecklist(makeChecklist())
        pushModel.selectAnswer(itemID: "a", choice: "pass")
        pushModel.applyChecklistPayload(Data(#"{"items":[]}"#.utf8))

        let fetchModel = DogfoodFeedbackModel(submitter: FakeSubmitter())
        fetchModel.applyChecklist(makeChecklist())
        fetchModel.selectAnswer(itemID: "a", choice: "pass")
        fetchModel.applyChecklist(.empty)

        #expect(pushModel.checklist == fetchModel.checklist)
        #expect(pushModel.checklist.isEmpty)
        #expect(fetchModel.checklist.isEmpty)
        #expect(pushModel.selection(for: "a") == nil)
        #expect(fetchModel.selection(for: "a") == nil)
        #expect(pushModel.answersPayload.answers.isEmpty)
        #expect(fetchModel.answersPayload.answers.isEmpty)
    }

    @Test func toggleExpandedFlipsTheState() {
        let model = DogfoodFeedbackModel(submitter: FakeSubmitter())
        #expect(!model.isExpanded)
        model.toggleExpanded()
        #expect(model.isExpanded)
        model.toggleExpanded()
        #expect(!model.isExpanded)
    }
}
#endif
