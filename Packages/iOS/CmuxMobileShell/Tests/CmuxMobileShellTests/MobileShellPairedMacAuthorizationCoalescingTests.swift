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
}
