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

/// Field-ownership tests for the terminal-switch draft swap: the visible field
/// represents a terminal's draft only after that terminal's stored draft has
/// actually been loaded into it (or the user has typed). Until then the field
/// is a transient cleared placeholder, and switching away must not persist that
/// placeholder over the terminal's real stored draft.
@MainActor
@Suite struct DraftSwitchOwnershipTests {
    private static func makeComposite(drafts: InMemoryTerminalDraftStore) -> MobileShellComposite {
        MobileShellComposite(
            workspaces: [
                MobileWorkspacePreview(
                    id: "ws-1",
                    name: "ws",
                    terminals: [
                        MobileTerminalPreview(id: "term-a", name: "a"),
                        MobileTerminalPreview(id: "term-b", name: "b"),
                        MobileTerminalPreview(id: "term-c", name: "c"),
                    ]
                ),
            ],
            draftStore: drafts
        )
    }

    @Test func fastSwitchThroughTerminalPreservesItsUntouchedDraft() async {
        let drafts = InMemoryTerminalDraftStore()
        await drafts.saveDraft("b draft", forTerminalID: "term-b")
        let composite = Self.makeComposite(drafts: drafts)

        // Type under A, then switch A -> B -> C before B's stored draft has
        // loaded into the field. The B -> C switch sees only the transient
        // cleared placeholder; saving it would erase B's real draft.
        composite.terminalInputText = "a text"
        composite.selectedTerminalID = MobileTerminalPreview.ID(rawValue: "term-b")
        composite.selectedTerminalID = MobileTerminalPreview.ID(rawValue: "term-c")
        await composite.drainDraftOperationsForTesting()

        #expect(await drafts.draft(forTerminalID: "term-a") == "a text")
        #expect(await drafts.draft(forTerminalID: "term-b") == "b draft")
    }

    @Test func lateLoadDoesNotResurrectTextDeletedDuringLoad() async {
        let drafts = InMemoryTerminalDraftStore()
        await drafts.saveDraft("b draft", forTerminalID: "term-b")
        let composite = Self.makeComposite(drafts: drafts)

        // Switch A -> B, then type and delete everything before B's stored
        // draft load applies. The user's live (deliberately emptied) input must
        // win: the late load cannot resurrect the deleted text into the field.
        composite.selectedTerminalID = MobileTerminalPreview.ID(rawValue: "term-b")
        composite.terminalInputText = "x"
        composite.terminalInputText = ""
        await composite.drainDraftOperationsForTesting()

        #expect(composite.terminalInputText.isEmpty)
        #expect(await drafts.draft(forTerminalID: "term-b") == nil)
    }
}
