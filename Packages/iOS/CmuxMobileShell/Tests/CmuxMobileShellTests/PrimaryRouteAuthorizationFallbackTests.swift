import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct PrimaryRouteAuthorizationFallbackTests {
    @Test func authorizationFailureDoesNotFallBackToTrustedManualHost() async throws {
        let clock = TestClock()
        let tailscaleRoute = try CmxAttachRoute(
            id: "preferred-tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50_922),
            priority: 0
        )
        let manualRoute = try CmxAttachRoute(
            id: "approved-manual-host",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: 50_923),
            priority: 10
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "candidate-workspace",
            terminalID: nil,
            macDeviceID: "candidate-mac",
            macDisplayName: "Candidate Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [tailscaleRoute, manualRoute],
            expiresAt: clock.now.addingTimeInterval(3_600)
        )
        let trustStore = InMemoryMobileManualHostTrustStore()
        let manualScope = try #require(
            MobileManualHostTrustScope(route: manualRoute, stackUserID: "phone-user")
        )
        await trustStore.trust(manualScope)
        let attempts = RouteAttemptRecorder()
        let runtime = LivenessTestRuntime(
            transportFactory: AuthorizationThenManualFallbackTransportFactory(
                router: LivenessHostRouter(),
                box: TransportBox(),
                attempts: attempts
            ),
            now: { clock.now },
            supportedRouteKinds: [.tailscale, .manualHost],
            supportsServerPushEvents: false
        )
        let store = MobileShellComposite(
            runtime: runtime,
            identityProvider: StaticIdentityProvider(userID: "phone-user"),
            reachability: AlwaysOnlineReachability(),
            manualHostTrustStore: trustStore
        )
        store.signIn()

        let result = await store.connectPairingURLResult(try attachURL(for: ticket))

        #expect(result == .failed)
        #expect(attempts.count(.tailscale) == 0)
        #expect(attempts.count(.manualHost) == 0)
        #expect(store.remoteClient == nil)
        #expect(store.manualHostTrustWarning == nil)
    }
}
