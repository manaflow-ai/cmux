import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

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
