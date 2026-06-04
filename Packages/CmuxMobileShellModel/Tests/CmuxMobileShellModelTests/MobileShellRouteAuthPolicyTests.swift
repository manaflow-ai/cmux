import CMUXMobileCore
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileShellRouteAuthPolicyTests {
    private func hostPortRoute(
        kind: CmxAttachTransportKind,
        host: String,
        port: Int,
        priority: Int = 0
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: kind.rawValue,
            kind: kind,
            endpoint: .hostPort(host: host, port: port),
            priority: priority
        )
    }

    @Test func allowsStackAuthOnlyForTrustedManualHostPortRoutes() throws {
        let loopback = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
        let tailscaleIP = try hostPortRoute(kind: .tailscale, host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
        let lanIP = try hostPortRoute(kind: .tailscale, host: "192.168.1.77", port: CmxMobileDefaults.defaultHostPort)
        let localDNS = try hostPortRoute(kind: .tailscale, host: "devbox.local", port: CmxMobileDefaults.defaultHostPort)
        let tailscaleMagicDNS = try hostPortRoute(kind: .tailscale, host: "work-mac.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)
        let pretendLoopback = try hostPortRoute(kind: .debugLoopback, host: "127.attacker.example", port: CmxMobileDefaults.defaultHostPort)

        #expect(MobileShellRouteAuthPolicy.manualRouteKind(for: "127.0.0.1") == .debugLoopback)
        #expect(MobileShellRouteAuthPolicy.manualRouteKind(for: "127.attacker.example") == .tailscale)
        #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(loopback))
        #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(tailscaleMagicDNS))
        #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(tailscaleIP))
        #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(lanIP))
        #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(localDNS))
        #expect(!MobileShellRouteAuthPolicy.routeAllowsStackAuth(pretendLoopback))
        #expect(!MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("127.0.0.1"))
        #expect(!MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("100.71.210.41"))
        #expect(!MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("work-mac.tailnet.ts.net"))
        #expect(MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("192.168.1.77"))
        #expect(MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("devbox.local"))
    }
}
