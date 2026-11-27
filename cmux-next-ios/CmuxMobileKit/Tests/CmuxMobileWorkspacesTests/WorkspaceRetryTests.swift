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
        await view.retryFirstLoad()
        #expect(loads == 1)
        #expect(store.teamDataState == .failed)
        await view.retryFirstLoad()
        #expect(loads == 2)
        #expect(store.teamDataState == .loaded)
    }

    /// AutoRetry's attempt ends when the reload has answered, not when it was asked for: the
    /// live reload only marks the team loading and answers later.
    @Test func autoRetryAttemptWaitsForTheReloadToAnswer() async {
        let store = AppStore.mock()
        store.teamDataState = .failed
        let creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero))
        let view = WorkspacesList(store: store, creator: creator, retryLoad: {
            store.teamDataState = .loading
            Task { @MainActor in
                await Task.yield()
                store.teamDataState = .failed
            }
        }, open: { _ in })
        await view.retryFirstLoad()
        #expect(store.teamDataState == .failed)
    }

    /// Offline, the page waits for the network: nothing is asked.
    @Test func autoRetryAsksNothingOffline() async {
        let store = AppStore.mock()
        store.teamDataState = .failed
        store.isOffline = true
        let creator = WorkspaceCreator(store: store, backend: MockWorkspaceCreationBackend(latency: .zero))
        var loads = 0
        let view = WorkspacesList(store: store, creator: creator, retryLoad: { loads += 1 }, open: { _ in })
        await view.retryFirstLoad()
        #expect(loads == 0)
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
