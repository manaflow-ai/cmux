import CMUXMobileCore
import Foundation
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

    @Test func routeIsLoopbackOnlyForLoopbackHostPortEndpoints() throws {
        let loopbackIP = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
        let localhost = try hostPortRoute(kind: .debugLoopback, host: "localhost", port: CmxMobileDefaults.defaultHostPort)
        let ipv6Loopback = try hostPortRoute(kind: .debugLoopback, host: "::1", port: CmxMobileDefaults.defaultHostPort)
        // Host decides, not the declared kind: a loopback host on a network
        // kind is still loopback, and a public host on the loopback kind is not.
        let loopbackOnNetworkKind = try hostPortRoute(kind: .tailscale, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
        let pretendLoopback = try hostPortRoute(kind: .debugLoopback, host: "127.attacker.example", port: CmxMobileDefaults.defaultHostPort)
        let tailscaleIP = try hostPortRoute(kind: .tailscale, host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
        let irohPeer = try CmxAttachRoute(
            id: CmxAttachTransportKind.iroh.rawValue,
            kind: .iroh,
            endpoint: .peer(id: "peer-1", relayHint: nil, directAddrs: [], relayURL: nil),
            priority: 0
        )

        #expect(MobileShellRouteAuthPolicy.routeIsLoopback(loopbackIP))
        #expect(MobileShellRouteAuthPolicy.routeIsLoopback(localhost))
        #expect(MobileShellRouteAuthPolicy.routeIsLoopback(ipv6Loopback))
        #expect(MobileShellRouteAuthPolicy.routeIsLoopback(loopbackOnNetworkKind))
        #expect(!MobileShellRouteAuthPolicy.routeIsLoopback(pretendLoopback))
        #expect(!MobileShellRouteAuthPolicy.routeIsLoopback(tailscaleIP))
        #expect(!MobileShellRouteAuthPolicy.routeIsLoopback(irohPeer))
    }

    @Test func allowsStackAuthOnlyForEncryptedLoopbackOrApprovedManualHostRoutes() throws {
        let loopback = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: CmxMobileDefaults.defaultHostPort)
        let tailscaleIP = try hostPortRoute(kind: .tailscale, host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
        let lanIP = try hostPortRoute(kind: .tailscale, host: "192.168.1.77", port: CmxMobileDefaults.defaultHostPort)
        let localDNS = try hostPortRoute(kind: .tailscale, host: "devbox.local", port: CmxMobileDefaults.defaultHostPort)
        let tailscaleMagicDNS = try hostPortRoute(kind: .tailscale, host: "work-mac.tailnet.ts.net", port: CmxMobileDefaults.defaultHostPort)
        let pretendLoopback = try hostPortRoute(kind: .debugLoopback, host: "127.attacker.example", port: CmxMobileDefaults.defaultHostPort)
        let irohPeer = try CmxAttachRoute(
            id: CmxAttachTransportKind.iroh.rawValue,
            kind: .iroh,
            endpoint: .peer(id: "peer-1", relayHint: nil, directAddrs: [], relayURL: nil),
            priority: 0
        )

        let manualHostRoute = try hostPortRoute(kind: .manualHost, host: "192.168.1.77", port: CmxMobileDefaults.defaultHostPort)

        #expect(MobileShellRouteAuthPolicy.manualRouteKind(for: "127.0.0.1") == .debugLoopback)
        #expect(MobileShellRouteAuthPolicy.manualRouteKind(for: "[::1]") == .debugLoopback)
        #expect(MobileShellRouteAuthPolicy.manualRouteKind(for: "100.71.210.41") == .tailscale)
        #expect(MobileShellRouteAuthPolicy.manualRouteKind(for: "work-mac.tailnet.ts.net") == .tailscale)
        #expect(MobileShellRouteAuthPolicy.manualRouteKind(for: "127.attacker.example") == .manualHost)

        // Encrypted / loopback channels and explicitly approved manual hosts may
        // carry the Stack bearer token.
        #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(loopback))
        #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(tailscaleMagicDNS))
        #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(tailscaleIP))
        #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(irohPeer))
        #expect(!MobileShellRouteAuthPolicy.routeAllowsStackAuth(manualHostRoute))
        #expect(MobileShellRouteAuthPolicy.routeAllowsStackAuth(manualHostRoute, manualHostTrusted: true))

        // Plaintext-TCP routes must NOT carry the Stack bearer token by default:
        // a `.tailscale` route to a private-LAN IP or a `.local`/Bonjour host is
        // dialed over unencrypted TCP, so it is excluded from the Stack-auth set.
        #expect(!MobileShellRouteAuthPolicy.routeAllowsStackAuth(lanIP))
        #expect(!MobileShellRouteAuthPolicy.routeAllowsStackAuth(localDNS))
        #expect(!MobileShellRouteAuthPolicy.routeAllowsStackAuth(pretendLoopback))

        #expect(!MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("127.0.0.1"))
        #expect(!MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("100.71.210.41"))
        #expect(!MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("work-mac.tailnet.ts.net"))
        #expect(MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("192.168.1.77"))
        #expect(MobileShellRouteAuthPolicy.manualHostNeedsTrustWarning("devbox.local"))
    }

    @Test func manualHostTrustScopeIsHostPortAndAccountScoped() async throws {
        let store = InMemoryMobileManualHostTrustStore()
        let approved = try #require(MobileManualHostTrustScope(
            host: "Studio-Mac.local",
            port: 58465,
            stackUserID: "user-a"
        ))
        let sameHostDifferentCase = try #require(MobileManualHostTrustScope(
            host: "studio-mac.local",
            port: 58465,
            stackUserID: "user-a"
        ))
        let differentPort = try #require(MobileManualHostTrustScope(
            host: "studio-mac.local",
            port: 58466,
            stackUserID: "user-a"
        ))
        let differentAccount = try #require(MobileManualHostTrustScope(
            host: "studio-mac.local",
            port: 58465,
            stackUserID: "user-b"
        ))
        let normalizedIPv6 = try #require(MobileManualHostTrustScope(
            host: "fd00::12",
            port: 58465,
            stackUserID: "user-a"
        ))
        let bracketedIPv6 = try #require(MobileManualHostTrustScope(
            host: "[fd00::12]",
            port: 58465,
            stackUserID: "user-a"
        ))

        #expect(!await store.isTrusted(approved))
        await store.trust(approved)
        await store.trust(normalizedIPv6)

        #expect(await store.isTrusted(sameHostDifferentCase))
        #expect(await store.isTrusted(bracketedIPv6))
        #expect(!await store.isTrusted(differentPort))
        #expect(!await store.isTrusted(differentAccount))
    }

    @Test func userDefaultsManualHostTrustExpiresApproval() async throws {
        let suiteName = "cmux-manual-host-trust-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let scope = try #require(MobileManualHostTrustScope(
            host: "studio-mac.local",
            port: 58465,
            stackUserID: "user-a"
        ))
        let key = "manual-host-trust"
        let writer = UserDefaultsMobileManualHostTrustStore(
            defaults: defaults,
            key: key,
            trustDuration: 60,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let stillValidReader = UserDefaultsMobileManualHostTrustStore(
            defaults: defaults,
            key: key,
            trustDuration: 60,
            now: { Date(timeIntervalSince1970: 1_059) }
        )
        let expiredReader = UserDefaultsMobileManualHostTrustStore(
            defaults: defaults,
            key: key,
            trustDuration: 60,
            now: { Date(timeIntervalSince1970: 1_061) }
        )

        await writer.trust(scope)

        #expect(await stillValidReader.isTrusted(scope))
        #expect(!await expiredReader.isTrusted(scope))
    }

    @Test func manualHostTrustWarningFormatsBracketedIPv6Once() throws {
        let scope = try #require(MobileManualHostTrustScope(
            host: "[fd00::12]",
            port: 58465,
            stackUserID: "user-a"
        ))

        #expect(MobileManualHostTrustWarning(scope: scope).endpoint == "[fd00::12]:58465")
        #expect(
            MobileManualHostTrustWarning(scope: scope, displayHost: "[fd00::12]").endpoint == "[fd00::12]:58465"
        )
    }

    @Test func physicalDeviceRejectsLoopbackTicketsInEveryGrammar() throws {
        // The v2 QR decoder rejects loopback itself; this policy is what stops
        // the LEGACY payload grammars from being a bypass on a physical phone,
        // where a loopback route dials the phone itself and loopback's
        // Stack-auth trust would hand the bearer token to a local listener.
        let loopback = try hostPortRoute(kind: .debugLoopback, host: "127.0.0.1", port: 56577)
        let loopbackUnderTailscaleKind = try hostPortRoute(kind: .tailscale, host: "127.0.0.1", port: 56577)
        let tailscale = try hostPortRoute(kind: .tailscale, host: "100.71.210.41", port: 56577)

        #expect(MobileShellRouteAuthPolicy.ticketRejectsLoopbackRoutes(
            [loopback], isPhysicalDevice: true
        ))
        #expect(MobileShellRouteAuthPolicy.ticketRejectsLoopbackRoutes(
            [loopbackUnderTailscaleKind], isPhysicalDevice: true
        ))
        // One loopback route poisons the ticket even when a real route rides along.
        #expect(MobileShellRouteAuthPolicy.ticketRejectsLoopbackRoutes(
            [tailscale, loopback], isPhysicalDevice: true
        ))
        #expect(!MobileShellRouteAuthPolicy.ticketRejectsLoopbackRoutes(
            [tailscale], isPhysicalDevice: true
        ))
        // The simulator flow legitimately pairs over loopback (127.0.0.1 IS
        // the host Mac there), so the policy never fires off-device.
        #expect(!MobileShellRouteAuthPolicy.ticketRejectsLoopbackRoutes(
            [loopback], isPhysicalDevice: false
        ))
    }
}
