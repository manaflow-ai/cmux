import Testing
@testable import CmuxMobileShell

@MainActor
@Test func cancelledAggregateCompletionCannotEraseReplacementRefresh() async throws {
    let router = RoutingHostRouter()
    let store = MobileShellComposite(
        connectionState: .connected,
        workspaces: MobileShellComposite.preview().workspaces
    )
    try installFreshRemoteClient(on: store, router: router)
    await router.workspaceListGate.setHoldFirst(true)
    await router.workspaceListGate.setHoldSecond(true)

    let cancelledRefresh = Task { await store.refreshWorkspaces() }
    await router.workspaceListGate.waitUntilFirstReached()
    store.remoteClient = nil
    try installFreshRemoteClient(on: store, router: router)

    let replacementRefresh = Task { await store.refreshWorkspaces() }
    await router.workspaceListGate.waitUntilSecondReached()
    let replacementTaskID = try #require(store.aggregateWorkspaceRefreshTaskID)
    await router.workspaceListGate.releaseFirst()
    await cancelledRefresh.value

    #expect(store.aggregateWorkspaceRefreshTask != nil)
    #expect(store.aggregateWorkspaceRefreshTaskID == replacementTaskID)
    let joiningRefresh = Task { await store.refreshWorkspaces() }
    await Task.yield()
    #expect(store.aggregateWorkspaceRefreshTaskID == replacementTaskID)

    await router.workspaceListGate.releaseSecond()
    await replacementRefresh.value
    await joiningRefresh.value
    #expect(await router.workspaceListGate.requestCount() == 2)
    #expect(store.aggregateWorkspaceRefreshTask == nil)
}
