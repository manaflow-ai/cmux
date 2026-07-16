import CmuxMobilePairedMac
@testable import CmuxMobileShell

/// Build a signed-in store that can run the real secondary aggregation path
/// while a test supplies an already-connected secondary subscription.
@MainActor
func makeRoutingMultiMacStore(
    router: RoutingHostRouter,
    pairedMacStore: any MobilePairedMacStoring
) -> MobileShellComposite {
    let runtime = RoutingTestRuntime(
        transportFactory: RoutingTransportFactory(router: router)
    )
    let store = MobileShellComposite(
        runtime: runtime,
        isSignedIn: true,
        pairedMacStore: pairedMacStore,
        identityProvider: StaticIdentityProvider(userID: "user-1"),
        teamIDProvider: { "team-a" }
    )
    store.foregroundMacDeviceID = "foreground-mac"
    return store
}
