import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// A ``TerminalDraftStoring`` whose FIRST `saveDraft` suspends for many
/// scheduler turns before applying. Actors are reentrant across suspension
/// points, so without an ordering guarantee a later operation's task overtakes
/// the suspended save and the stale save applies last. With the composite's
/// FIFO draft pipeline, the delayed save must fully apply before any later
/// operation starts, regardless of how long it suspends.
private actor DelayingDraftStore: TerminalDraftStoring {
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

/// Ordering tests for the composite's FIFO draft pipeline: store effects must
/// apply in exactly the order they were issued, so a stale keystroke save can
/// never overwrite a newer save, and nothing written before the sign-out wipe
/// survives it.
@MainActor
@Suite struct DraftPipelineOrderingTests {
    private static func makeComposite(drafts: DelayingDraftStore) -> MobileShellComposite {
        MobileShellComposite(
            workspaces: [
                MobileWorkspacePreview(
                    id: "ws-1",
                    name: "ws",
                    terminals: [MobileTerminalPreview(id: "term-a", name: "a")]
                ),
            ],
            draftStore: drafts
        )
    }

    @Test func slowEarlierSaveCannotOverwriteNewerSave() async {
        let drafts = DelayingDraftStore()
        let composite = Self.makeComposite(drafts: drafts)

        // Two keystrokes in quick succession; the first save suspends long
        // enough that an unordered later save would overtake it and the stale
        // "a" would apply last.
        composite.terminalInputText = "a"
        composite.terminalInputText = "ab"
        await composite.drainDraftOperationsForTesting()

        let stored = await drafts.draft(forTerminalID: "term-a")
        #expect(stored == "ab")
    }

    @Test func slowEarlierSaveCannotSurviveSignOutWipe() async {
        let drafts = DelayingDraftStore()
        let composite = Self.makeComposite(drafts: drafts)

        // A keystroke save is still suspended when sign-out wipes the store; the
        // wipe must apply AFTER that save, so the previous account's unsent text
        // cannot leak into the next session.
        composite.terminalInputText = "secret unsent text"
        composite.signOut()
        await composite.drainDraftOperationsForTesting()

        let stored = await drafts.draft(forTerminalID: "term-a")
        #expect(stored == nil)
    }
}
