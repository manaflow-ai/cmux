import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct StoredMacReconnectAuthorityTests {
    @Test func reconnectUsesAuthoritativeTicketMacIdentity() async throws {
        let route = try loopbackRoute(id: "identity", port: 51_007)
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [storedMac(id: "mac-a", route: route)]],
            blockedTeams: []
        )
        let router = LivenessHostRouter()
        await router.setAttachTicketMacDeviceID("mac-b")
        await router.setHostIdentity(deviceID: "mac-b", instanceTag: "default")
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(connected)
        #expect(store.foregroundMacDeviceIDForTesting() == "mac-b")
        #expect(store.activeTicket?.macDeviceID == "mac-b")
        store.signOut()
    }

    @Test func reconnectRejectsHostIdentityThatContradictsTicket() async throws {
        let route = try loopbackRoute(id: "contradicting-identity", port: 51_015)
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [storedMac(id: "mac-a", route: route)]],
            blockedTeams: []
        )
        let router = LivenessHostRouter()
        await router.setAttachTicketMacDeviceID("mac-b")
        await router.setHostIdentity(deviceID: "mac-a", instanceTag: "default")
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(!connected)
        #expect(store.foregroundMacDeviceIDForTesting() == nil)
        #expect(store.activeTicket == nil)
        store.signOut()
    }

    @Test func reconnectAuthorizationFailureRequiresReauthentication() async throws {
        let route = try loopbackRoute(id: "unauthorized", port: 51_008)
        let pairedMacStore = DelayedTeamPairedMacStore(
            recordsByTeam: ["": [storedMac(id: "mac-a", route: route)]],
            blockedTeams: []
        )
        let router = LivenessHostRouter()
        await router.failRequests(
            method: "mobile.attach_ticket.create",
            code: "unauthorized",
            message: "Unauthorized"
        )
        let store = MobileShellComposite(
            runtime: LivenessTestRuntime(
                transportFactory: LivenessTransportFactory(
                    router: router,
                    box: TransportBox()
                ),
                now: { Date() }
            ),
            isSignedIn: true,
            pairedMacStore: pairedMacStore,
            identityProvider: StaticIdentityProvider(userID: "user-1")
        )

        let connected = await store.reconnectActiveMacIfAvailable(stackUserID: "user-1")

        #expect(!connected)
        #expect(store.connectionRequiresReauth)
        #expect(store.connectionState == .disconnected)
    }

    private func loopbackRoute(id: String, port: Int) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        )
    }

    private func storedMac(id: String, route: CmxAttachRoute) -> MobilePairedMac {
        MobilePairedMac(
            macDeviceID: id,
            displayName: id,
            routes: [route],
            createdAt: Date(),
            lastSeenAt: Date(),
            isActive: true,
            stackUserID: "user-1"
        )
    }
}
