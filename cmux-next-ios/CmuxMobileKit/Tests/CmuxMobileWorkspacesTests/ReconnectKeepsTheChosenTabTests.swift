import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

#if os(iOS)
/// Leo, 2026-11-21: "i lost connection with cosmic gray or some s*** refreshed or the connection f***ing
/// lagged and then it brought me out of the terminal tab and into a browser tab". The live screen's hold
/// (StickyTabSelectionTests) covers a screen that stays up; these cover one rebuilt while the Mac's list
/// still lacks the tab, and a Mac close of another tab meanwhile.
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
    /// stays. The chosen tab itself closing moves it to its neighbour.
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
        source.dropClosedTabs(["t-zsh"])
        #expect(source.activeTabID == "t-docs")
    }
}
#endif
