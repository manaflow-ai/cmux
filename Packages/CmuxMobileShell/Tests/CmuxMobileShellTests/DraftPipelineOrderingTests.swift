import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

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
