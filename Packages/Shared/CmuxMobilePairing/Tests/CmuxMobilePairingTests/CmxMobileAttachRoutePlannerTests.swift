import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobilePairing

@Suite("Mobile attach route planning")
struct CmxMobileAttachRoutePlannerTests {
    private let planner = CmxMobileAttachRoutePlanner()

    @Test("physical-device selection retains each explicitly advertised class")
    func physicalDeviceSelectionRetainsAdvertisedRoutes() throws {
        let routes = [
            try route(id: "iroh", kind: .iroh, host: "ignored"),
            try route(id: "lan_9", kind: .lan, host: "192.168.1.10"),
            try route(id: "tailscale_4", kind: .tailscale, host: "100.64.1.10"),
        ]

        let selected = try planner.selectRoutes(
            for: .physicalDevice,
            from: routes
        )

        #expect(selected.map(\.kind) == [.iroh, .lan, .tailscale])
        #expect(selected.map(\.id) == ["iroh", "lan", "tailscale"])
    }

    @Test("simulator selection prefers identity-only Iroh routes")
    func simulatorSelectionPrefersIrohIdentity() throws {
        let identity = try CmxIrohPeerIdentity(endpointID: String(repeating: "ab", count: 32))
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: identity,
                pathHints: [
                    try CmxIrohPathHint(
                        kind: .relayURL,
                        value: "https://relay.example/",
                        source: .native,
                        privacyScope: .publicInternet
                    ),
                ]
            )
        )

        let selected = try planner.selectRoutes(
            for: .simulatorInjection,
            from: [iroh]
        )

        #expect(selected.count == 1)
        guard case let .peer(selectedIdentity, hints) = selected[0].endpoint else {
            Issue.record("expected an identity-only Iroh route")
            return
        }
        #expect(selectedIdentity == identity)
        #expect(hints.isEmpty)
    }

    @Test("canonical route IDs and priorities are rebuilt from the filtered sequence")
    func canonicalRoutesAreReindexed() throws {
        let routes = [
            try route(id: "tailscale_7", kind: .tailscale, host: "100.64.1.7"),
            try route(id: "tailscale_8", kind: .tailscale, host: "100.64.1.8"),
        ]

        let canonical = try planner.canonicalTailscaleRoutes(from: routes)

        #expect(canonical.map(\.id) == ["tailscale", "tailscale_2"])
        #expect(canonical.map(\.priority) == [10, 20])
    }

    private func route(
        id: String,
        kind: CmxAttachTransportKind,
        host: String
    ) throws -> CmxAttachRoute {
        if kind == .iroh {
            let identity = try CmxIrohPeerIdentity(endpointID: String(repeating: "cd", count: 32))
            return try CmxAttachRoute(
                id: id,
                kind: kind,
                endpoint: .peer(identity: identity, pathHints: [])
            )
        }
        return try CmxAttachRoute(
            id: id,
            kind: kind,
            endpoint: .hostPort(host: host, port: 49_831)
        )
    }

    @Test("host route builder keeps LAN and Tailscale priority grids disjoint")
    func hostRouteBuilderUsesDisjointPriorities() throws {
        let builder = CmxMobileHostRouteBuilder()
        let routes = builder.routes(
            port: 58_465,
            tailscaleHosts: ["100.64.0.2", "100.64.0.3"],
            lanHosts: ["192.168.1.2", "192.168.1.3"]
        )
        #expect(routes.map(\.kind) == [.lan, .lan, .tailscale, .tailscale])
        #expect(routes.map(\.priority) == [5, 15, 10, 20])
        #expect(Set(routes.map(\.priority)).count == routes.count)
    }

    @Test("host route builder rejects tunnel and link-local addresses")
    func hostRouteBuilderFiltersNonLANHosts() {
        let builder = CmxMobileHostRouteBuilder()
        let routes = builder.routes(
            port: 58_465,
            tailscaleHosts: ["100.64.0.2", "192.168.1.2"],
            lanHosts: ["fe80::1", "10.0.0.2", "100.64.0.3"]
        )
        #expect(routes.map(\.kind) == [.lan, .tailscale])
        #expect(routes.map { $0.endpoint } == [
            .hostPort(host: "10.0.0.2", port: 58_465),
            .hostPort(host: "100.64.0.2", port: 58_465),
        ])
    }

    @Test("physical-device projection keeps route classes and strips Iroh hints")
    func physicalDeviceProjectionPreservesRoutes() throws {
        let identity = try CmxIrohPeerIdentity(endpointID: String(repeating: "ef", count: 32))
        let hint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://relay.example/",
            source: .native,
            privacyScope: .publicInternet
        )
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(identity: identity, pathHints: [hint]),
            priority: 0
        )
        let lan = try route(id: "lan", kind: .lan, host: "192.168.1.2")
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac",
            macDisplayName: "Mac",
            routes: [iroh, lan],
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            authToken: "secret"
        )
        let projected = try CmxMobileAttachTicketProjector().physicalDeviceTicket(
            ticket,
            routes: [iroh, lan]
        )
        #expect(projected.routes.map(\.kind) == [
            CmxAttachTransportKind.iroh,
            CmxAttachTransportKind.lan,
        ])
        #expect(projected.authToken == nil)
        guard case let .peer(projectedIdentity, projectedHints) = projected.routes[0].endpoint else {
            Issue.record("expected projected Iroh peer")
            return
        }
        #expect(projectedIdentity == identity)
        #expect(projectedHints.isEmpty)
    }

    @Test("legacy compact projection drops LAN and credential material")
    func legacyCompactProjectionDropsUnsupportedFields() throws {
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace",
            terminalID: "terminal",
            macDeviceID: "mac",
            macDisplayName: "Mac",
            macUserEmail: "user@example.com",
            routes: [try route(id: "tailscale", kind: .tailscale, host: "100.64.0.2"),
                     try route(id: "lan", kind: .lan, host: "192.168.1.2")],
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            authToken: "secret"
        )
        let projected = try CmxMobileAttachTicketProjector().legacyCompactTicket(
            ticket,
            disclosureMode: .legacyPrivateNetworkCompatibility
        )
        #expect(projected.routes.map(\.kind) == [CmxAttachTransportKind.tailscale])
        #expect(projected.authToken == nil)
        #expect(projected.expiresAt == nil)
        #expect(projected.macUserEmail == nil)
    }
}
