import AppKit
import CmuxNextDesign
import os

/// The quit's unsaved-changes step (R96 quit hook), before the terminals
/// question. An interactive quit asks "Save changes before quitting?"
/// (Save, Don't Save, Cancel) and loops on failures with their reasons;
/// signal, power-off and update save unattended (3 s cap) and keep the
/// drafts of what failed; a scripted quit refuses when a save fails.
@MainActor
enum QuitUnsavedStep {
    static let unattendedCap: Duration = .seconds(3)
    static let saveID = "save"
    static let dontSaveID = "dont-save"

    /// True when the quit may continue. A failed save asks again, with
    /// its reason; each turn waits for the person's answer.
    static func resolveInteractive(_ registry: QuitUnsavedRegistry, scope: CmuxDialogScope,
                                   center: CmuxDialogCenter = .shared, failures: [String: String] = [:]) async -> Bool {
        let participants = registry.unsaved()
        if participants.isEmpty { return true }
        let answer = await center.present(spec(participants, failures: failures), in: scope)
        switch answer.button {
        case dontSaveID:
            await registry.discard(participants)
            return true
        case saveID:
            guard let outcomes = await saveShowingProgress(registry, participants, scope: scope, center: center) else { return false }
            let failed = Dictionary(outcomes.compactMap { outcome in outcome.reason.map { (outcome.id, $0) } }) { first, _ in first }
            return await resolveInteractive(registry, scope: scope, center: center, failures: failed)
        default:
            return false
        }
    }

    /// The question: one line per document, with the reason a save failed.
    static func spec(_ participants: [any QuitUnsavedParticipant], failures: [String: String]) -> CmuxDialogSpec {
        let lines = participants.map { participant in
            failures[participant.quitParticipantID].map { QuitStrings.unsavedFailed(participant.quitTitle, $0) } ?? participant.quitTitle
        }
        return CmuxDialogSpec(
            title: QuitStrings.unsavedTitle, lines: lines,
            buttons: [CmuxDialogButton(id: dontSaveID, title: QuitStrings.unsavedDontSave, role: .destructive, key: "d"),
                      .cancel(ConfirmationStrings.cancel),
                      CmuxDialogButton(id: saveID, title: QuitStrings.unsavedSave, role: .default)],
            identifier: "cmux.dialog.quitUnsaved")
    }

    /// Saves while "Saving <title>…" shows with Cancel. Nil when the person
    /// cancelled (the quit stops; a write in progress finishes on its own).
    static func saveShowingProgress(_ registry: QuitUnsavedRegistry, _ participants: [any QuitUnsavedParticipant],
                                    scope: CmuxDialogScope, center: CmuxDialogCenter) async -> [QuitFlushOutcome]? {
        let progress = CmuxDialogSpec(title: QuitStrings.unsavedTitle,
                                      lines: participants.map { QuitStrings.unsavedSaving($0.quitTitle) },
                                      buttons: [.cancel(ConfirmationStrings.cancel)], identifier: "cmux.dialog.quitUnsavedSaving")
        return await withCheckedContinuation { (continuation: CheckedContinuation<[QuitFlushOutcome]?, Never>) in
            let race = SaveRace(continuation)
            race.dialogID = center.present(progress, in: scope) { _ in race.finish(nil) }
            Task { @MainActor in
                let outcomes = await registry.save(participants)
                if race.finish(outcomes), let id = race.dialogID { center.dismiss(id) }
            }
        }
    }

    /// The save against the person's Cancel: the first one answers.
    @MainActor
    final class SaveRace {
        private var continuation: CheckedContinuation<[QuitFlushOutcome]?, Never>?
        var dialogID: Int?

        init(_ continuation: CheckedContinuation<[QuitFlushOutcome]?, Never>) {
            self.continuation = continuation
        }

        /// True when this call answered (the other side came too late).
        @discardableResult
        func finish(_ outcomes: [QuitFlushOutcome]?) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(returning: outcomes)
            return true
        }
    }

    /// Signal, power-off, update, scripted: saves with the 3 s cap, never
    /// asks. A failed save keeps its recovery draft; it is logged by id.
    static func saveUnattended(_ registry: QuitUnsavedRegistry) async -> [QuitFlushOutcome] {
        let participants = registry.unsaved()
        guard !participants.isEmpty else { return [] }
        let outcomes = await registry.save(participants, deadlineCap: unattendedCap)
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.quit")
        for outcome in outcomes where outcome.result != .saved {
            logger.error("quit save failed for \(outcome.id, privacy: .public); recovery draft kept")
        }
        return outcomes
    }

    /// The scripted quit's refusal, naming what did not save; nil to quit.
    static func refusal(_ outcomes: [QuitFlushOutcome]) -> String? {
        let failed = outcomes.filter { $0.result != .saved }.map(\.title)
        return failed.isEmpty ? nil : QuitStrings.unsavedRefused(failed.joined(separator: ", "))
    }
}
