import Testing
@testable import CmuxMobileShell

@MainActor
@Test func failedSecondaryFetchIsNotAnAuthoritativeMutationRefresh() async throws {
    let store = MobileShellComposite.preview()
    let router = RoutingHostRouter()
    let macID = "secondary-refresh"
    try installSecondaryClient(on: store, macDeviceID: macID, router: router)
    await router.setRejectWorkspaceList(true)
    let subscription = try #require(store.secondaryMacSubscriptions[macID])
    let target = WorkspaceMutationTarget(
        client: subscription.client,
        isForeground: false,
        macDeviceID: macID
    )

    let refreshed = await store.refreshAfterWorkspaceMutation(target)

    #expect(!refreshed)
    #expect(subscription.refreshCompletedGeneration == 0)
}
