import Foundation
import Testing
@testable import CmuxMobileShell

/// Behavior tests for ``InMemoryTerminalDraftStore``: per-terminal keying,
/// empty-draft removal, and clear semantics.
@Suite struct InMemoryTerminalDraftStoreTests {
    @Test func savesAndLoadsPerTerminal() async {
        let store = InMemoryTerminalDraftStore()
        await store.saveDraft("git status", forTerminalID: "term-a")
        await store.saveDraft("npm test", forTerminalID: "term-b")

        let a = await store.draft(forTerminalID: "term-a")
        let b = await store.draft(forTerminalID: "term-b")
        #expect(a == "git status")
        #expect(b == "npm test")
        // A terminal with no draft reads nil, not another terminal's text.
        let missing = await store.draft(forTerminalID: "term-c")
        #expect(missing == nil)
    }

    @Test func emptyOrWhitespaceDraftRemovesEntry() async {
        let store = InMemoryTerminalDraftStore()
        await store.saveDraft("hello", forTerminalID: "term-a")
        await store.saveDraft("   \n ", forTerminalID: "term-a")
        let restored = await store.draft(forTerminalID: "term-a")
        #expect(restored == nil)
    }

    @Test func clearDraftRemovesOnlyThatTerminal() async {
        let store = InMemoryTerminalDraftStore()
        await store.saveDraft("keep", forTerminalID: "term-a")
        await store.saveDraft("drop", forTerminalID: "term-b")
        await store.clearDraft(forTerminalID: "term-b")
        let a = await store.draft(forTerminalID: "term-a")
        let b = await store.draft(forTerminalID: "term-b")
        #expect(a == "keep")
        #expect(b == nil)
    }

    @Test func clearAllDraftsEmptiesEveryTerminal() async {
        let store = InMemoryTerminalDraftStore()
        await store.saveDraft("a", forTerminalID: "term-a")
        await store.saveDraft("b", forTerminalID: "term-b")
        await store.clearAllDrafts()
        let a = await store.draft(forTerminalID: "term-a")
        let b = await store.draft(forTerminalID: "term-b")
        #expect(a == nil)
        #expect(b == nil)
    }
}
