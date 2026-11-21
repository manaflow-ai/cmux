import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// Leo, 2026-11-21: "i lost connection with cosmic gray ... and then it brought me out of the
/// terminal tab and into a browser tab and my drafted message on ios in the fucking round composer
/// got lost". A reconnect keeps the tab the person was on and what they had typed.
@Suite struct TerminalComposerDraftsTests {
    let key = TerminalFrameKey(accountID: "acct", macID: "mac", surfaceID: "s1")

    func defaults() throws -> UserDefaults {
        let name = "TerminalComposerDraftsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aDraftWaitsForTheTabsNextHostAndARelaunch() throws {
        let defaults = try defaults()
        var drafts = TerminalComposerDrafts(defaults: defaults)
        drafts.keep("git commit -m 'half typed", for: key)
        #expect(drafts.draft(for: key) == "git commit -m 'half typed")
        // A cold launch reads it back.
        #expect(TerminalComposerDrafts(defaults: defaults).draft(for: key) == "git commit -m 'half typed")
        // Another account, Mac or surface never sees it.
        #expect(drafts.draft(for: TerminalFrameKey(accountID: "other", macID: "mac", surfaceID: "s1")) == nil)
        #expect(drafts.draft(for: TerminalFrameKey(accountID: "acct", macID: "mac2", surfaceID: "s1")) == nil)
        #expect(drafts.draft(for: TerminalFrameKey(accountID: "acct", macID: "mac", surfaceID: "s2")) == nil)
    }

    @Test func aClearedOrClosedDraftGoes() throws {
        let defaults = try defaults()
        var drafts = TerminalComposerDrafts(defaults: defaults)
        drafts.keep("ls", for: key)
        drafts.keep("", for: key)
        #expect(drafts.draft(for: key) == nil)
        #expect(TerminalComposerDrafts(defaults: defaults).draft(for: key) == nil)
        drafts.keep("ls", for: key)
        drafts.remove(key)
        #expect(TerminalComposerDrafts(defaults: defaults).draft(for: key) == nil)
    }

    @Test func overTheByteCapTheOldestGoesFirst() {
        var drafts = TerminalComposerDrafts(defaults: nil)
        let big = String(repeating: "x", count: TerminalComposerDrafts.byteLimit / 2 + 1)
        let older = TerminalFrameKey(accountID: "acct", macID: "mac", surfaceID: "old")
        drafts.keep(big, for: older)
        drafts.keep(big, for: key)
        #expect(drafts.draft(for: older) == nil)
        #expect(drafts.draft(for: key) == big)
        // The newest is kept even alone over the cap.
        let huge = String(repeating: "y", count: TerminalComposerDrafts.byteLimit + 1)
        drafts.keep(huge, for: key)
        #expect(drafts.draft(for: key) == huge)
    }
}

#if os(iOS)
@MainActor @Suite struct ReconnectKeepsTheChosenTabTests {
    /// ws-cmux lists t-claude (agent), t-zsh (terminal), t-docs (browser).
    func store() -> AppStore { AppStore.mock(tabMemory: .inMemory([:])) }

    func setTabs(_ store: AppStore, _ ids: [String], from all: [WorkspaceTab]) {
        store.workspaces = store.workspaces.map { workspace in
            guard workspace.id == "ws-cmux" else { return workspace }
            var workspace = workspace
            workspace.tabs = all.filter { ids.contains($0.id) }
            return workspace
        }
    }

    /// The screen is rebuilt while a lagging Mac's list lacks the terminal (a refresh, a redial):
    /// it shows another tab meanwhile, never remembers that one, and is back on the terminal when
    /// the full list returns.
    @Test func aRebuiltScreenWaitsForTheTerminalToBeListedAgain() throws {
        let store = store()
        let all = try #require(store.workspace(id: "ws-cmux")).tabs
        let first = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux")
        first.opened()
        first.activate("t-zsh")
        #expect(first.activeTabID == "t-zsh")

        setTabs(store, ["t-claude", "t-docs"], from: all)
        let rebuilt = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux")
        rebuilt.opened()
        #expect(rebuilt.activeTabID != "t-zsh")
        #expect(store.lastActiveTabByWorkspace["ws-cmux"] == "t-zsh")
        #expect(store.lastTabByWorkspace["ws-cmux"] == "t-zsh")

        setTabs(store, ["t-claude", "t-zsh", "t-docs"], from: all)
        rebuilt.refreshTabs(preparingCards: false)
        #expect(rebuilt.activeTabID == "t-zsh")
        // A screen built after the list is whole opens there too.
        #expect(WorkspaceTabsSource(store: store, workspaceID: "ws-cmux").activeTabID == "t-zsh")
    }

    /// The Mac closes another tab while the chosen terminal is missing from its list: the choice
    /// stays.
    @Test func anotherTabClosingKeepsAMissingChoice() throws {
        let store = store()
        let all = try #require(store.workspace(id: "ws-cmux")).tabs
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux")
        source.opened()
        source.activate("t-zsh")
        setTabs(store, ["t-claude", "t-docs"], from: all)
        source.refreshTabs(preparingCards: false)
        source.dropClosedTabs(["t-claude"])
        setTabs(store, ["t-zsh", "t-docs"], from: all)
        source.refreshTabs(preparingCards: false)
        #expect(source.activeTabID == "t-zsh")
        // The chosen tab itself closing moves the choice.
        source.dropClosedTabs(["t-zsh"])
        #expect(source.activeTabID == "t-docs")
    }
}
#endif
