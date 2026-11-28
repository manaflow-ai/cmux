import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct CmxIrohPrivatePathSynthesizerTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func addsFallbackOnlyTailscaleHintWithoutChangingPeerIdentity() throws {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [])
        )
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50906)
        )

        let routes = CmxAttachRoute.addingIrohPrivatePaths(
            to: [iroh, tailscale],
            observedAt: now
        )

        #expect(routes.map(\.kind) == [.iroh, .tailscale])
        guard case let .peer(resultIdentity, hints) = routes[0].endpoint else {
            Issue.record("Expected Iroh peer endpoint")
            return
        }
        #expect(resultIdentity == identity)
        let hint = try #require(hints.first)
        #expect(hint.value == "100.82.214.112:50906")
        #expect(hint.source == .tailscale)
        #expect(hint.privacyScope == .privateNetwork)
        #expect(hint.use == .fallbackOnly)
        #expect(hint.observedAt == now)
        #expect(hint.expiresAt == now.addingTimeInterval(
            CmxIrohPathHint.maximumPrivateHintTTL
        ))
        #expect(hint.networkProfile
            == CmxIrohNetworkProfileKey.activeTailscaleTunnel)
    }

    @Test func ignoresMagicDNSAndGenericPrivateNetworkRoutes() throws {
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: []
            )
        )
        let magicDNS = try CmxAttachRoute(
            id: "magic-dns",
            kind: .tailscale,
            endpoint: .hostPort(host: "work-mac.tailnet.ts.net", port: 50906)
        )
        let genericLAN = try CmxAttachRoute(
            id: "lan",
            kind: .tailscale,
            endpoint: .hostPort(host: "192.168.1.20", port: 50906)
        )

        let routes = CmxAttachRoute.addingIrohPrivatePaths(
            to: [iroh, magicDNS, genericLAN],
            observedAt: now
        )

        guard case let .peer(_, hints) = routes[0].endpoint else {
            Issue.record("Expected Iroh peer endpoint")
            return
        }
        #expect(hints.isEmpty)
    }

    @Test func refreshReplacesSameAddressInsteadOfAccumulatingHints() throws {
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "fd7a:115c:a1e0::4b36:d670", port: 50906)
        )
        let originalHint = try #require(
            tailscale.irohTailscalePathHint(observedAt: now)
        )
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "b", count: 64)
                ),
                pathHints: [originalHint]
            )
        )
        let refreshedAt = now.addingTimeInterval(60)

        let routes = CmxAttachRoute.addingIrohPrivatePaths(
            to: [iroh, tailscale],
            observedAt: refreshedAt
        )

        guard case let .peer(_, hints) = routes[0].endpoint else {
            Issue.record("Expected Iroh peer endpoint")
            return
        }
        #expect(hints.count == 1)
        #expect(hints[0].value == "[fd7a:115c:a1e0::4b36:d670]:50906")
        #expect(hints[0].observedAt == refreshedAt)
    }

    @Test func expiredHintsDoNotConsumeFreshTailscaleCapacity() throws {
        let expiredAt = now.addingTimeInterval(-1)
        let expiredHint = try CmxIrohPathHint(
            kind: .directAddress,
            value: "100.82.214.111:50906",
            source: .tailscale,
            privacyScope: .privateNetwork,
            observedAt: expiredAt.addingTimeInterval(-60),
            expiresAt: expiredAt,
            networkProfile: .activeTailscaleTunnel
        )
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "c", count: 64)
                ),
                pathHints: Array(
                    repeating: expiredHint,
                    count: CmxAttachEndpoint.maximumIrohPathHintCount
                )
            )
        )
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.112", port: 50906)
        )

        let routes = CmxAttachRoute.addingIrohPrivatePaths(
            to: [iroh, tailscale],
            observedAt: now
        )

        guard case let .peer(_, hints) = routes[0].endpoint else {
            Issue.record("Expected Iroh peer endpoint")
            return
        }
        #expect(hints.count == 1)
        #expect(hints[0].value == "100.82.214.112:50906")
        #expect(hints[0].isUsable(at: now))
    }
}
