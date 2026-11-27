#if os(iOS)
import CmuxMobileModel
import Testing
@testable import CmuxMobileWorkspaces

@MainActor @Suite struct WorkspaceRetryTests {
    @Test func retryRunsTheLoaderAndKeepsFailureUntilItSucceeds() async {
        let store = AppStore.mock()
        store.teamDataState = .failed
        let creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero))
        var loads = 0
        let view = WorkspacesList(store: store, creator: creator, retryLoad: {
            loads += 1
            if loads == 2 { store.teamDataState = .loaded }
        }, open: { _ in })
        await view.retry()
        #expect(loads == 1)
        #expect(store.teamDataState == .failed)
        await view.retry()
        #expect(loads == 2)
        #expect(store.teamDataState == .loaded)
    }

    @Test func placeholderRetriesItsOwnWorkspaceLoader() async throws {
        let store = AppStore.mock()
        let workspace = try #require(store.workspaces.first)
        var loaded: [String] = []
        let source = PlaceholderTerminalTabContent { loaded.append($0.id) }
        await source.retry(workspace)
        #expect(loaded == [workspace.id])
    }
}
#endif
