#if os(iOS)
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// A tab row dropped on the Panes page (`WorkspaceTabsSource.dropTab`): the page and the grid
/// show it in its new place at once (one settle), and a refusal from the Mac puts both back.
@MainActor @Suite struct PaneDropSourceTests {
    /// ws-cmux (Claude, zsh, docs) laid out as Claude, docs | zsh.
    func make() -> (AppStore, MockWorkspaceCreationBackend, WorkspaceTabsSource) {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        store.setLayout(WorkspaceLayout(screens: [WorkspaceLayout.Screen(id: 1, isActive: true, panes: [
            WorkspaceLayout.Pane(id: 1, tabIDs: ["t-claude", "t-docs"], activeTabID: "t-claude", isFocused: true),
            WorkspaceLayout.Pane(id: 2, tabIDs: ["t-zsh"], activeTabID: "t-zsh"),
        ], root: .split(id: 9, axis: .horizontal, ratio: 0.5, first: .pane(1), second: .pane(2)))]), in: "ws-cmux")
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", creator: WorkspaceCreator(store: store, backend: backend))
        return (store, backend, source)
    }

    @Test func aDropShowsTheTabInItsNewPaneAtOnce() async throws {
        let (_, _, source) = make()
        let right = try #require(source.layout?.pane(2))
        let task = try #require(source.dropTab("t-docs", into: right, at: 0))
        // Before the Mac answers: the page and the grid already have it there.
        #expect(source.layout?.pane(1)?.tabIDs == ["t-claude"])
        #expect(source.layout?.pane(2)?.tabIDs == ["t-docs", "t-zsh"])
        #expect(source.workspace?.tabs.map(\.id) == ["t-claude", "t-docs", "t-zsh"])
        await task.value
        #expect(source.layout?.pane(2)?.tabIDs == ["t-docs", "t-zsh"])
        #expect(source.toastText == nil)
    }

    @Test func aRefusalPutsItBack() async throws {
        let (_, backend, source) = make()
        backend.failNext = "The Mac refused."
        let right = try #require(source.layout?.pane(2))
        let task = try #require(source.dropTab("t-docs", into: right, at: 1))
        #expect(source.layout?.pane(2)?.tabIDs == ["t-zsh", "t-docs"])
        await task.value
        #expect(source.layout?.pane(1)?.tabIDs == ["t-claude", "t-docs"])
        #expect(source.layout?.pane(2)?.tabIDs == ["t-zsh"])
        #expect(source.workspace?.tabs.map(\.id) == ["t-claude", "t-zsh", "t-docs"])
        #expect(source.toastText != nil)
    }

    @Test func aDropOnItsOwnPlaceDoesNothing() throws {
        let (_, _, source) = make()
        let left = try #require(source.layout?.pane(1))
        #expect(source.dropTab("t-docs", into: left, at: 1) == nil)
        #expect(source.dropTab("t-docs", into: left, at: 2) == nil)
    }
}
#endif
