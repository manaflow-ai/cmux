import Foundation
@testable import CmuxMobileShell

/// A test ``TerminalDraftStoring`` whose FIRST `saveDraft` suspends for many
/// scheduler turns before applying. Actors are reentrant across suspension
/// points, so without an ordering guarantee a later operation's task overtakes
/// the suspended save and the stale save applies last. With the composite's
/// FIFO draft pipeline, the delayed save must fully apply before any later
/// operation starts, regardless of how long it suspends.
actor DelayingDraftStore: TerminalDraftStoring {
    private var drafts: [String: String] = [:]
    private var delayedFirstSave = false

    func draft(forTerminalID terminalID: String) async -> String? {
        drafts[terminalID]
    }

    func saveDraft(_ draft: String, forTerminalID terminalID: String) async {
        if !delayedFirstSave {
            delayedFirstSave = true
            for _ in 0..<50 { await Task.yield() }
        }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[terminalID] = nil
        } else {
            drafts[terminalID] = draft
        }
    }

    func clearDraft(forTerminalID terminalID: String) async {
        drafts[terminalID] = nil
    }

    func clearAllDrafts() async {
        drafts.removeAll()
    }
}
