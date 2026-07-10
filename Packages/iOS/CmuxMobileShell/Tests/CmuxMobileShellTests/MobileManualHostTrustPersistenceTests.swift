import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileManualHostTrustPersistenceTests {
    @Test func approvalThatWasNotPersistedPromptsAgainWithoutSendingCredentials() async {
        let router = LivenessHostRouter()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(
                router: router,
                box: TransportBox()
            ),
            now: { Date() },
            supportedRouteKinds: [.manualHost]
        )
        let store = MobileShellComposite(
            runtime: runtime,
            isSignedIn: true,
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            pairingHintDefaults: UserDefaults(
                suiteName: "manual-host-refused-trust-\(UUID().uuidString)"
            )!,
            manualHostTrustStore: RefusingManualHostTrustStore()
        )

        let queued = await store.connectManualHost(
            name: "LAN Mac",
            host: "192.168.1.77",
            port: 58_465
        )
        let resumed = await store.acceptManualHostTrustWarning()

        #expect(queued == .needsUserApproval)
        #expect(resumed == .needsUserApproval)
        #expect(store.manualHostTrustWarning?.endpoint == "192.168.1.77:58465")
        #expect(await router.count(of: "mobile.attach_ticket.create") == 0)
        #expect(await router.count(of: "workspace.list") == 0)
    }
}
