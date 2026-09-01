import CMUXMobileCore
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
}
