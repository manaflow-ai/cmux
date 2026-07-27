import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for ``MobileShellComposite/reconcileComposerDraftAfterSend(sentText:submittedTerminalID:)``,
/// the post-ack step of a composer send. The send itself goes over RPC (covered
/// by the feature-level scripted-transport tests); these tests drive the
/// reconciliation directly with a controlled draft store and selection, covering
/// the switched-terminal-mid-flight cases that cannot be reached through the
/// preview host.
@MainActor
@Suite struct ComposerSubmitDraftReconcileTests {
    private static let terminalA = MobileTerminalPreview(id: "term-a", name: "a")
    private static let terminalB = MobileTerminalPreview(id: "term-b", name: "b")

    /// A composite whose initial selection is `term-a`, wired to `drafts`.
    /// Selection is set by `init` (no `didSet` draft swap fires), so the store
    /// contents stay exactly what each test seeds.
    private static func makeComposite(drafts: InMemoryTerminalDraftStore) -> MobileShellComposite {
        MobileShellComposite(
            workspaces: [
                MobileWorkspacePreview(id: "ws-1", name: "ws", terminals: [terminalA, terminalB]),
            ],
            draftStore: drafts
        )
    }

    @Test func clearsStoredDraftWhenSelectionMovedMidFlight() async {
        let drafts = InMemoryTerminalDraftStore()
        let composite = Self.makeComposite(drafts: drafts)
        // The user sent from term-b, then switched to term-a before the ack; the
        // switch persisted the outgoing (sent) text as term-b's draft.
        await drafts.saveDraft("deploy it", forTerminalID: "term-b")

        await composite.reconcileComposerDraftAfterSend(sentText: "deploy it", submittedTerminalID: "term-b")

        // The sent text must not survive as term-b's draft (switching back would
        // resurrect already-sent text and invite a duplicate submission).
        let stored = await drafts.draft(forTerminalID: "term-b")
        #expect(stored == nil)
        // The currently selected terminal's field is untouched.
        #expect(composite.terminalInputText.isEmpty)
    }

    @Test func preservesNewerStoredDraftWhenSelectionMovedMidFlight() async {
        let drafts = InMemoryTerminalDraftStore()
        let composite = Self.makeComposite(drafts: drafts)
        // The user tapped Send, typed MORE for term-b, then switched away; the
        // stored draft is newer than the sent text and must win.
        await drafts.saveDraft("deploy it && verify", forTerminalID: "term-b")

        await composite.reconcileComposerDraftAfterSend(sentText: "deploy it", submittedTerminalID: "term-b")

        let stored = await drafts.draft(forTerminalID: "term-b")
        #expect(stored == "deploy it && verify")
    }

    @Test func clearsVisibleFieldWhenSelectionUnchanged() async {
        let drafts = InMemoryTerminalDraftStore()
        let composite = Self.makeComposite(drafts: drafts)
        composite.terminalInputText = "ls -la"

        await composite.reconcileComposerDraftAfterSend(sentText: "ls -la", submittedTerminalID: "term-a")

        #expect(composite.terminalInputText.isEmpty)
    }

    @Test func keepsVisibleFieldEditedWhileSendInFlight() async {
        let drafts = InMemoryTerminalDraftStore()
        let composite = Self.makeComposite(drafts: drafts)
        // The user kept typing while the ack was in flight; the newer field
        // content must not be discarded.
        composite.terminalInputText = "ls -la && pwd"

        await composite.reconcileComposerDraftAfterSend(sentText: "ls -la", submittedTerminalID: "term-a")

        #expect(composite.terminalInputText == "ls -la && pwd")
    }
}
