import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

/// Regression coverage for Tailscale-only rows that retain an older Iroh route.
/// A named manual grant has no numeric Iroh pin and must remain dialable at the
/// exact host the user authorized.
@MainActor
@Suite struct TailscaleReconnectRouteSelectionTests {
    @Test func namedGrantSurvivesIrohRouteWithoutNumericPin() throws {
        let named = try CmxAttachRoute(
            id: "tailscale-name",
            kind: .tailscale,
            endpoint: .hostPort(
                host: "work-mac.tailnet.ts.net",
                port: 50906
            ),
            priority: 10
        )
        let iroh = try CmxAttachRoute(
            id: "iroh-personal",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            ),
            priority: -10_000
        )
        let routes = MobileShellComposite.storedReconnectRoutes(
            [named, iroh],
            supportedKinds: [.iroh, .tailscale],
            preferNonLoopback: true,
            tailscaleRequirement: MobileTailscaleRouteAuthorizer.Requirement(
                macDeviceID: "test-mac",
                grantRoutes: [],
                userGrantRoutes: [named]
            )
        )

        #expect(routes.map(\.endpoint) == [named.endpoint])
    }
}
