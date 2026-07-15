import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

@MainActor
extension ReconnectRouteSelectionTests {
    private func manualHost(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "manual_host",
            kind: .manualHost,
            endpoint: .hostPort(host: "192.168.1.77", port: port),
            priority: 2
        )
    }

    private func magicDNS(_ port: Int = 50906) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "lawrences-macbook-pro-2.tail137216.ts.net", port: port),
            priority: 5
        )
    }

    @Test func physicalDevicePrefersIPLiteralOverMagicDNSHostname() throws {
        let ip = try CmxAttachRoute(
            id: "tailscale_2",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50922),
            priority: 10
        )
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback(50922), try magicDNS(50922), ip],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "100.82.214.112")
    }

    @Test func magicDNSHostnameStillUsedWhenNoIPRouteExists() throws {
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback(50922), try magicDNS(50922)],
            supportedKinds: [.debugLoopback, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "lawrences-macbook-pro-2.tail137216.ts.net")
    }

    @Test func tailscaleDNSBeatsManualHostIPFallback() throws {
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback(50922), try manualHost(50922), try magicDNS(50922)],
            supportedKinds: [.debugLoopback, .manualHost, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "lawrences-macbook-pro-2.tail137216.ts.net")
    }

    @Test func tailscaleDNSBeatsLegacyLANRouteStoredAsTailscale() throws {
        let pick = MobileShellRouteSelection().firstReconnectHostPortRoute(
            [try loopback(50922), try legacyLANStoredAsTailscale(50922), try magicDNS(50922)],
            supportedKinds: [.debugLoopback, .manualHost, .tailscale],
            preferNonLoopback: true
        )
        #expect(pick?.0 == "lawrences-macbook-pro-2.tail137216.ts.net")
    }

    @Test func ipLiteralHostClassification() {
        #expect(MobileShellRouteSelection().isIPLiteralHost("100.82.214.112"))
        #expect(MobileShellRouteSelection().isIPLiteralHost("127.0.0.1"))
        #expect(MobileShellRouteSelection().isIPLiteralHost("fd7a:115c:a1e0::4b36:d670"))
        #expect(MobileShellRouteSelection().isIPLiteralHost("::ffff:192.168.0.1"))
        #expect(MobileShellRouteSelection().isIPLiteralHost("[fd7a:115c:a1e0::4b36:d670]"))
        #expect(!MobileShellRouteSelection().isIPLiteralHost("lawrences-macbook-pro-2.tail137216.ts.net"))
        #expect(!MobileShellRouteSelection().isIPLiteralHost("example.com"))
        #expect(!MobileShellRouteSelection().isIPLiteralHost("my:host"))
        #expect(!MobileShellRouteSelection().isIPLiteralHost("100.82.214"))
        #expect(!MobileShellRouteSelection().isIPLiteralHost("256.1.1.1"))
    }
}
