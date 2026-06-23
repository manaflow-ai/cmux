import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

/// A restored/published Mac advertises both a `debug_loopback` route
/// (`127.0.0.1`, priority 0) and a `tailscale` route. On a physical phone the
/// loopback route names the phone itself and can never reach the Mac, so route
/// selection must prefer the real route there — otherwise tapping a saved Mac
/// dials the phone's own loopback and silently fails to connect.
@MainActor
@Suite struct ReconnectRouteSelectionTests {
    private func loopback(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: 0
        )
    }

    private func tailscale(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: port),
            priority: 10
        )
    }

    @Test func physicalDevicePrefersRealRouteOverLowerPriorityLoopback() throws {
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "100.82.214.112") // tailscale, not the phone's 127.0.0.1
    }

    @Test func physicalDeviceFallsBackToLoopbackWhenItIsTheOnlyRoute() throws {
        // The on-device XCUITest mock host serves a real listener on 127.0.0.1.
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "127.0.0.1")
    }

    @Test func simulatorKeepsLoopbackPriorityOrder() throws {
        // On the simulator 127.0.0.1 IS the host Mac, so priority order stands.
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback(), try tailscale()],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: false
        )
        #expect(pick?.0 == "127.0.0.1")
    }

    private func magicDNS(_ port: Int = 50906) throws -> CmxAttachRoute {
        // A MagicDNS hostname route, advertised BEFORE the IP route by priority.
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "lawrences-macbook-pro-2.tail137216.ts.net", port: port),
            priority: 5
        )
    }

    @Test func physicalDevicePrefersIPLiteralOverMagicDNSHostname() throws {
        // The exact dogfood failure: a Mac advertises loopback, a MagicDNS
        // hostname (higher priority), and the raw tailscale IP. MagicDNS doesn't
        // resolve on the phone, so dialing the hostname times out; selection must
        // pick the IP literal so the secondary fetch / reconnect actually connects.
        let ip = try CmxAttachRoute(
            id: "tailscale_2",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50922),
            priority: 10
        )
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback(50922), try magicDNS(50922), ip],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "100.82.214.112")
    }

    @Test func magicDNSHostnameStillUsedWhenNoIPRouteExists() throws {
        // If the only non-loopback route is a hostname, still prefer it over
        // loopback on device (better than dialing the phone's own 127.0.0.1).
        let pick = MobileShellComposite.firstReconnectHostPortRoute(
            [try loopback(50922), try magicDNS(50922)],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "lawrences-macbook-pro-2.tail137216.ts.net")
    }

    @Test func ipLiteralHostClassification() {
        #expect(MobileShellComposite.isIPLiteralHost("100.82.214.112"))
        #expect(MobileShellComposite.isIPLiteralHost("127.0.0.1"))
        #expect(MobileShellComposite.isIPLiteralHost("fd7a:115c:a1e0::4b36:d670"))
        #expect(!MobileShellComposite.isIPLiteralHost("lawrences-macbook-pro-2.tail137216.ts.net"))
        #expect(!MobileShellComposite.isIPLiteralHost("example.com"))
        #expect(!MobileShellComposite.isIPLiteralHost("100.82.214")) // too few octets
        #expect(!MobileShellComposite.isIPLiteralHost("256.1.1.1")) // out of range
    }
}
