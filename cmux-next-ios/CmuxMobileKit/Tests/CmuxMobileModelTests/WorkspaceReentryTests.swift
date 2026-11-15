import Foundation
import Testing
@testable import CmuxMobileModel

/// Back to the list and into the same workspace again: it opens on the tab that was on screen
/// there, not on its first tab. Leo, 2026-11-14: "when I go back to the workspace, it opens it
/// up at the first one instead of my recently opened one, which seems kind of weird if it's
/// still loaded on my phone".
@MainActor @Suite struct WorkspaceReentryTests {
    typealias Layout = WorkspaceLayout
    typealias Pane = WorkspaceLayout.Pane

    /// ws-cmux laid out as zsh | (Claude, docs), the right pane focused on the Mac.
    func laidOut() throws -> AppStore {
        let store = AppStore.mock(tabMemory: .inMemory())
        var ws = try #require(store.workspace(id: "ws-cmux"))
        ws.activeTabID = "t-claude"
        ws.layout = Layout(screens: [Layout.Screen(id: 1, isActive: true, panes: [
            Pane(id: 2, tabIDs: ["t-claude", "t-docs"], activeTabID: "t-claude", isFocused: true),
            Pane(id: 1, tabIDs: ["t-zsh"], activeTabID: "t-zsh"),
        ], root: .split(id: 9, axis: .horizontal, ratio: 0.5, first: .pane(1), second: .pane(2)))])
        store.workspaces = store.workspaces.map { $0.id == ws.id ? ws : $0 }
        return store
    }

    @Test func reenteringAWorkspaceOpensTheTabLastOnScreenThere() throws {
        let store = try laidOut()
        let ws = try #require(store.workspace(id: "ws-cmux"))
        // The first open in this launch: the top-left pane's active tab.
        #expect(store.openingTab(for: ws)?.id == "t-zsh")
        // The person moves to docs, then goes back to the list and taps the row again.
        store.noteOpened(tabID: "t-docs", in: ws.id)
        #expect(store.openingTab(for: ws)?.id == "t-docs")
    }

    @Test func aTabTheOpenNamesStillWins() throws {
        let store = try laidOut()
        let ws = try #require(store.workspace(id: "ws-cmux"))
        store.noteOpened(tabID: "t-docs", in: ws.id)
        // A notification, a Feed card or a search result names its tab.
        store.requestOpen(tabID: "t-claude", in: ws.id)
        #expect(store.openingTab(for: ws)?.id == "t-claude")
        store.takeRequestedTab(ws.id)
        // That tab was then on screen: it is the one to go back to.
        #expect(store.openingTab(for: ws)?.id == "t-claude")
    }

    @Test func aLastActiveTabTheMacClosedFallsBackToTheTopLeft() throws {
        let store = try laidOut()
        store.noteOpened(tabID: "t-docs", in: "ws-cmux")
        store.workspaces = store.workspaces.map { ws in
            guard ws.id == "ws-cmux" else { return ws }
            var closed = ws
            closed.tabs.removeAll { $0.id == "t-docs" }
            return closed
        }
        let ws = try #require(store.workspace(id: "ws-cmux"))
        #expect(store.openingTab(for: ws)?.id == "t-zsh")
    }

    @Test func aLastActiveTabClosedHereOpensOnTheTabShownInItsPlace() throws {
        let store = try laidOut()
        store.noteOpened(tabID: "t-zsh", in: "ws-cmux")
        // Closing the tab on screen shows its right neighbor, docs.
        #expect(store.removeTab("t-zsh", from: "ws-cmux")?.id == "t-docs")
        let ws = try #require(store.workspace(id: "ws-cmux"))
        #expect(store.openingTab(for: ws)?.id == "t-docs")
    }

    /// Only a workspace still loaded in this launch reopens where it was left: after a relaunch
    /// the saved tab is for the launch restore, and any other open starts at the top-left.
    @Test func aRelaunchStartsAtTheTopLeftAgain() throws {
        let suite = "cmuxMobile.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppStore.mock(tabMemory: TabMemory(defaults: defaults))
        first.noteOpened(tabID: "t-docs", in: "ws-cmux")
        #expect(first.openingTab(for: try #require(first.workspace(id: "ws-cmux")))?.id == "t-docs")
        let relaunched = AppStore.mock(tabMemory: TabMemory(defaults: defaults))
        #expect(relaunched.lastTabByWorkspace["ws-cmux"] == "t-docs")
        #expect(relaunched.openingTab(for: try #require(relaunched.workspace(id: "ws-cmux")))?.id == "t-claude")
    }
}

/// `WorkspaceOpeningTab` alone: the order of its inputs, each skipped when the workspace no
/// longer lists its tab.
@MainActor @Suite struct WorkspaceOpeningTabTests {
    func cmux() throws -> Workspace {
        var ws = try #require(AppStore.mock(tabMemory: .inMemory()).workspace(id: "ws-cmux"))
        ws.activeTabID = "t-claude"
        ws.layout = WorkspaceLayout(screens: [WorkspaceLayout.Screen(id: 1, isActive: true, panes: [
            WorkspaceLayout.Pane(id: 2, tabIDs: ["t-claude", "t-docs"], activeTabID: "t-claude", isFocused: true),
            WorkspaceLayout.Pane(id: 1, tabIDs: ["t-zsh"], activeTabID: "t-zsh"),
        ], root: .split(id: 9, axis: .horizontal, ratio: 0.5, first: .pane(1), second: .pane(2)))])
        return ws
    }

    @Test func requestedThenLastActiveThenTopLeft() throws {
        let ws = try cmux()
        #expect(WorkspaceOpeningTab().tab(in: ws)?.id == "t-zsh")
        #expect(WorkspaceOpeningTab(lastActive: "t-docs").tab(in: ws)?.id == "t-docs")
        #expect(WorkspaceOpeningTab(requested: "t-claude", lastActive: "t-docs").tab(in: ws)?.id == "t-claude")
    }

    @Test func aGoneTabIsSkipped() throws {
        var ws = try cmux()
        #expect(WorkspaceOpeningTab(requested: "gone", lastActive: "t-docs").tab(in: ws)?.id == "t-docs")
        #expect(WorkspaceOpeningTab(lastActive: "gone").tab(in: ws)?.id == "t-zsh")
        // No layout: the Mac's active tab, then the first.
        ws.layout = nil
        #expect(WorkspaceOpeningTab(lastActive: "gone").tab(in: ws)?.id == "t-claude")
        ws.activeTabID = nil
        #expect(WorkspaceOpeningTab().tab(in: ws)?.id == ws.tabs.first?.id)
        ws.tabs = []
        #expect(WorkspaceOpeningTab(lastActive: "t-docs").tab(in: ws) == nil)
    }
}
