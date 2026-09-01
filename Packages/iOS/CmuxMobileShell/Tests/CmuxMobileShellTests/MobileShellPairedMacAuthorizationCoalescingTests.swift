import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellPairedMacAuthorizationCoalescingTests {
    @Test
    func authorizedRowRemainsRepresentativeWhenAnUntrustedAliasIsFresher() throws {
        let route = try CmxAttachRoute(
            id: "tailnet",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50922)
        )
        let authorized = MobilePairedMac(
            macDeviceID: "authorized",
            displayName: "Studio Mac",
            routes: [route],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 10),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            instanceTag: "default",
            connectionMethodRawValue: MobileConnectionMethod.tailscale.rawValue,
            userAuthorizedTailscaleRoutes: [route]
        )
        let untrusted = MobilePairedMac(
            macDeviceID: "untrusted",
            displayName: "Studio Mac",
            routes: [route],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 20),
            isActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            instanceTag: "default"
        )

        let representatives = MobileShellComposite.coalescePairedMacsByDialEndpoint(
            [authorized, untrusted],
            supportedKinds: [.tailscale],
            preferNonLoopback: true
        )

        #expect(representatives.count == 1)
        #expect(representatives.first?.macDeviceID == "authorized")
        #expect(representatives.first?.userAuthorizedTailscaleRoutes == [route])
    }

    @Test
    func namedGrantBeatsFailClosedIrohAliasForTailscaleOnlyPairing() throws {
        let namedRoute = try CmxAttachRoute(
            id: "magic-dns",
            kind: .tailscale,
            endpoint: .hostPort(host: "studio.tailnet.ts.net", port: 50922)
        )
        let peer = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let irohRoute = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(identity: peer, pathHints: [])
        )
        let failClosedIrohRow = MobilePairedMac(
            macDeviceID: "iroh-row",
            displayName: "Studio Mac",
            // Keep the raw host first so the display-only fallback shares the
            // same host key as the separately authorized duplicate.
            routes: [namedRoute, irohRoute],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 30),
            isActive: true,
            stackUserID: "user-1",
            teamID: "team-a",
            instanceTag: "default",
            connectionMethodRawValue: MobileConnectionMethod.tailscale.rawValue
        )
        let authorizedRow = MobilePairedMac(
            macDeviceID: "named-row",
            displayName: "Studio Mac",
            routes: [namedRoute],
            createdAt: Date(timeIntervalSince1970: 1),
            lastSeenAt: Date(timeIntervalSince1970: 10),
            isActive: false,
            stackUserID: "user-1",
            teamID: "team-a",
            instanceTag: "default",
            connectionMethodRawValue: MobileConnectionMethod.tailscale.rawValue,
            userAuthorizedTailscaleRoutes: [namedRoute]
        )

        let representatives = MobileShellComposite.coalescePairedMacsByDialEndpoint(
            [failClosedIrohRow, authorizedRow],
            // Model a physical build whose route capability currently admits
            // only the direct host lane; the stale Iroh identity is therefore
            // a display alias but not a usable dial route.
            supportedKinds: [.tailscale],
            preferNonLoopback: true
        )

        #expect(representatives.count == 1)
        #expect(representatives.first?.macDeviceID == "named-row")
        #expect(representatives.first?.userAuthorizedTailscaleRoutes == [namedRoute])
    }
}
