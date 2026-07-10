import CMUXMobileCore
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileIrohPinPolicyTests {
    private let policy = MobileIrohPinPolicy()

    private func iroh(_ endpointID: String, priority: Int = 0) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "iroh-\(endpointID)",
            kind: .iroh,
            endpoint: .peer(id: endpointID, relayHint: nil, directAddrs: [], relayURL: nil),
            priority: priority
        )
    }

    private func tailscale() throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 8443)
        )
    }

    @Test func classifiesTrustedFirstTrustAndMismatchRoutes() throws {
        #expect(policy.classification(for: try iroh("endpoint-a"), pinnedEndpointID: "endpoint-a") == .dialable)
        #expect(policy.classification(for: try iroh("endpoint-a"), pinnedEndpointID: nil) == .firstTrust("endpoint-a"))
        #expect(
            policy.classification(for: try iroh("endpoint-b"), pinnedEndpointID: "endpoint-a")
                == .mismatch(pinned: "endpoint-a", advertised: "endpoint-b")
        )
        #expect(policy.classification(for: try tailscale(), pinnedEndpointID: "endpoint-a") == .dialable)
    }

    @Test func mismatchRoutesAreExcludedFromReconnectCandidates() throws {
        let routes = [
            try iroh("attacker", priority: 0),
            try tailscale(),
        ]
        let filtered = policy.tokenBearingDialableRoutes(routes, pinnedEndpointID: "trusted")
        #expect(filtered.map(\.kind) == [.tailscale])
        let candidates = MobileShellComposite.reconnectRouteCandidates(
            filtered,
            supportedKinds: [.tailscale, .iroh],
            preferNonLoopback: true
        )
        #expect(candidates.map(\.kind) == [.tailscale])
    }

    @Test func reTrustUpdatesClassification() throws {
        let route = try iroh("new-endpoint")
        #expect(policy.hasMismatch(routes: [route], pinnedEndpointID: "old-endpoint"))
        #expect(policy.classification(for: route, pinnedEndpointID: "new-endpoint") == .dialable)
    }
}
