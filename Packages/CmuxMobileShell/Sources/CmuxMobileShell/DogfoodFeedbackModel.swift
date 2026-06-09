#if DEBUG
public import CmuxMobileShellModel
public import Foundation
import Observation

/// Drives the floating, hideable DEV dogfood pane (P2 of the Mac↔phone feedback
/// loop): holds the agent-pushed "what to check" checklist, the dogfooder's
/// per-item multiple-choice answers, the shared freeform note, and the
/// expand/submit UI state, and runs the "Capture & Send" submit.
///
/// `@MainActor @Observable`, built once in the app composition root and injected
/// into the floating-pane window and the shell. DEBUG-only; it does not exist in
/// release builds.
///
/// The model is the single source of truth for the pane. Pane rows read value
/// snapshots (``DogfoodChecklistItem`` + the current selection) and call back
/// through ``selectAnswer(itemID:choice:)``, never holding a reference to the
/// model — so the snapshot-boundary rule for `ForEach` subtrees holds.
///
/// The actual transport (export the diagnostic log, gather the terminal text,
/// build + send the `dogfood.feedback.submit` request) is injected as a
/// ``DogfoodFeedbackSubmitting`` seam so the model is testable without a live
/// connection and never reaches across modules for the surface/diagnostic
/// accessors.
@MainActor
@Observable
public final class DogfoodFeedbackModel {
    /// The current checklist pushed by the agent. Empty until the first push or
    /// fetch; the pane shows just the freeform note in that case.
    public private(set) var checklist: DogfoodChecklist = .empty

    /// The current selection per item id (the raw choice value), built up as the
    /// dogfooder answers. Absent ids are unanswered.
    public private(set) var selections: [String: String] = [:]

    /// The shared freeform note across all questions.
    public var note: String = ""

    /// Whether the pane is expanded into the full overlay (vs. collapsed to the
    /// draggable bug pill).
    public var isExpanded: Bool = false

    /// True while a "Capture & Send" submit is in flight (disables the button).
    public private(set) var isSubmitting: Bool = false

    /// The outcome of the most recent submit, for a transient pane banner. `nil`
    /// until the first submit completes.
    public private(set) var lastSubmitSucceeded: Bool?

    private let submitter: any DogfoodFeedbackSubmitting

    /// Creates the model.
    /// - Parameter submitter: The seam that captures and sends a feedback bundle.
    public init(submitter: any DogfoodFeedbackSubmitting) {
        self.submitter = submitter
    }

    /// Replace the checklist with a freshly pushed/fetched one.
    ///
    /// A selection is preserved only when the new checklist still has an item with
    /// that id *and* that item still offers the selected choice. This drops an
    /// answer whose item disappeared (so it can't ride along on the next submit)
    /// and also one whose item kept its id but changed its choices (so the pane
    /// can't submit a stale choice that the dogfooder can no longer see or pick).
    /// - Parameter checklist: The new checklist from the agent.
    public func applyChecklist(_ checklist: DogfoodChecklist) {
        self.checklist = checklist
        // Build the valid-choice map without trapping on duplicate ids: an agent
        // can push a malformed checklist with repeated ids, and the contract is
        // that a bad payload is ignored, not a crash. A later duplicate id just
        // unions its choices onto the earlier one's valid set.
        var validChoicesByID: [String: Set<String>] = [:]
        for item in checklist.items {
            validChoicesByID[item.id, default: []].formUnion(item.choices)
        }
        selections = selections.filter { id, choice in
            validChoicesByID[id]?.contains(choice) ?? false
        }
    }

    /// Decode and apply a checklist from a raw `dogfood.checklist` event payload
    /// or `dogfood.checklist.fetch` result. A malformed payload is ignored so a
    /// bad push can't crash or blank the pane.
    /// - Parameter payloadJSON: The raw JSON bytes, if any.
    public func applyChecklistPayload(_ payloadJSON: Data?) {
        guard let payloadJSON,
              let decoded = try? DogfoodChecklist.decode(payloadJSON) else { return }
        applyChecklist(decoded)
    }

    /// Record the dogfooder's selection for one item. Selecting the already
    /// selected choice clears it (so a question can be un-answered back to
    /// skipped).
    /// - Parameters:
    ///   - itemID: The answered item's stable id.
    ///   - choice: The chosen raw choice value.
    public func selectAnswer(itemID: String, choice: String) {
        if selections[itemID] == choice {
            selections.removeValue(forKey: itemID)
        } else {
            selections[itemID] = choice
        }
    }

    /// The current selection for an item, or `nil` if unanswered.
    /// - Parameter itemID: The item's stable id.
    /// - Returns: The selected raw choice value, or `nil`.
    public func selection(for itemID: String) -> String? {
        selections[itemID]
    }

    /// Toggle the pane between the pill and the expanded overlay.
    public func toggleExpanded() {
        isExpanded.toggle()
    }

    /// The freeform note is capped at this character count in ``answersPayload``
    /// so a pasted multi-MiB note cannot bloat the submitted answers JSON (it
    /// also rides in the submit's separately capped `text` field). Matches the
    /// shell + Mac feedback text caps.
    public static let maxNoteChars = 16_384

    /// The answers payload for the current selections, in checklist order, with
    /// unanswered items omitted, plus the (capped) freeform note.
    ///
    /// Built in checklist order (not dictionary order) so the bundle is
    /// deterministic and reads top-to-bottom like the pane. The note is capped
    /// here so the MC answers are never dropped just because the note is large.
    public var answersPayload: DogfoodFeedbackAnswers {
        let ordered = checklist.items.compactMap { item -> DogfoodFeedbackAnswer? in
            guard let choice = selections[item.id] else { return nil }
            return DogfoodFeedbackAnswer(id: item.id, choice: choice)
        }
        return DogfoodFeedbackAnswers(answers: ordered, note: String(note.prefix(Self.maxNoteChars)))
    }

    /// Capture a chrome screenshot + terminal text + diagnostics + the current
    /// answers and send them to the paired Mac's `dogfood.feedback.submit` sink.
    ///
    /// Sets ``isSubmitting`` for the duration and records ``lastSubmitSucceeded``.
    /// On success it clears only the answers + note that were actually submitted
    /// and have not changed since: the `submit` await is a reentrancy point, so a
    /// dogfooder may re-answer an item, type more note text, or a new checklist
    /// may arrive while the request is in flight; those in-flight edits must
    /// survive rather than be wiped by the success path. The checklist stays so
    /// the next capture starts clean. Fire-and-forget from the UI.
    public func captureAndSend() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        let payload = answersPayload
        // Snapshot exactly what was submitted, so the success-path clear only
        // touches state that is still the submitted value. Merge without trapping
        // on duplicate ids: `applyChecklist` tolerates a malformed checklist with
        // repeated ids, and `answersPayload` emits one answer per row, so a
        // duplicate id could otherwise trap here on Capture & Send.
        let submittedSelections = Dictionary(
            payload.answers.map { ($0.id, $0.choice) },
            uniquingKeysWith: { _, latest in latest }
        )
        let submittedNote = note
        let ok = await submitter.submit(answers: payload)
        isSubmitting = false
        lastSubmitSucceeded = ok
        guard ok else { return }
        // Clear each submitted answer only if it is still the submitted choice
        // (an in-flight re-answer is preserved).
        for (id, choice) in submittedSelections where selections[id] == choice {
            selections.removeValue(forKey: id)
        }
        // Clear the note only if it was not edited while the request was in
        // flight.
        if note == submittedNote {
            note = ""
        }
    }
}
#endif
