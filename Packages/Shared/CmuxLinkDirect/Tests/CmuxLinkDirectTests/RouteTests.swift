import CmuxLink
import CmuxLinkTesting
@testable import CmuxLinkDirect
import Testing

@Suite("Direct routes")
struct RouteTests {
    static let wifi = DirectInterface(name: "en0", kind: .wifi)
    static let cell = DirectInterface(name: "pdp_ip0", kind: .cellular)
    static let utun = DirectInterface(name: "utun4", kind: .other)

    static func snapshot(_ interfaces: [DirectInterface], satisfied: Bool = true) -> DirectPathSnapshot {
        DirectPathSnapshot(isSatisfied: satisfied, interfaces: interfaces)
    }

    @Test("route availability by address class and interfaces")
    func evaluator() {
        let evaluator = DirectRouteEvaluator()
        #expect(evaluator.status(for: .loopback, on: Self.snapshot([], satisfied: false)) == .available)
        #expect(evaluator.status(for: .tailscale, on: Self.snapshot([Self.cell])) == .unavailable(.noTunnel))
        #expect(evaluator.status(for: .tailscale, on: Self.snapshot([Self.cell, Self.utun])) == .available)
        #expect(evaluator.status(for: .tailscale, on: Self.snapshot([Self.utun], satisfied: false)) == .unavailable(.offline))
        #expect(evaluator.status(for: .privateNetwork, on: Self.snapshot([Self.cell])) == .unavailable(.noLocalNetwork))
        #expect(evaluator.status(for: .privateNetwork, on: Self.snapshot([Self.wifi])) == .available)
        #expect(evaluator.status(for: .privateNetwork, on: Self.snapshot([Self.cell, Self.utun])) == .available)
        #expect(evaluator.status(for: .publicNetwork, on: Self.snapshot([Self.cell])) == .available)
        #expect(evaluator.status(for: .publicNetwork, on: Self.snapshot([], satisfied: false)) == .unavailable(.offline))
        let bonjour = DirectEndpoint.Target.service(name: "Studio", type: DirectEndpoint.serviceType, domain: "local.")
        #expect(evaluator.status(for: bonjour, on: Self.snapshot([Self.cell])) == .unavailable(.noLocalNetwork))
        #expect(evaluator.status(for: bonjour, on: Self.snapshot([Self.wifi])) == .available)
        #expect(!DirectInterface(name: "en5", kind: .other).isTunnel)
    }

    @Test("the planner races only direct while its route works")
    func planner() throws {
        let network = LoopbackNetwork()
        let direct = DirectCarrier(identity: DirectIdentity())
        let other = network.carrier(kind: .webrtc, path: .p2p)
        let planner = DirectRoutePlanner()
        let tailnet = DirectEndpoint(address: try #require(DirectAddress("100.90.1.1")), hostKey: DirectIdentity().publicKey)

        let up = planner.carriers(direct: direct, endpoints: [tailnet], snapshot: Self.snapshot([Self.cell, Self.utun]), others: [other])
        #expect(up.map(\.kind) == [.direct])
        let down = planner.carriers(direct: direct, endpoints: [tailnet], snapshot: Self.snapshot([Self.cell]), others: [other])
        #expect(down.map(\.kind) == [.webrtc])
        let failed = planner.carriers(
            direct: direct, endpoints: [tailnet], snapshot: Self.snapshot([Self.utun]), others: [other], directFailed: true
        )
        #expect(failed.map(\.kind) == [.direct, .webrtc])
        let unknown = planner.carriers(direct: direct, endpoints: [tailnet], snapshot: nil, others: [other])
        #expect(unknown.map(\.kind) == [.direct, .webrtc])
        let none = planner.carriers(direct: direct, endpoints: [], snapshot: Self.snapshot([Self.wifi]), others: [other])
        #expect(none.map(\.kind) == [.webrtc])
    }

    @Test("connect refuses at once when no endpoint's route can work")
    func carrierRefusesDeadRoute() async throws {
        struct Offline: DirectRouteProvider {
            var currentSnapshot: DirectPathSnapshot? { RouteTests.snapshot([RouteTests.cell]) }
        }
        let resolver = DirectHintsResolver()
        let endpoint = DirectEndpoint(address: try #require(DirectAddress("100.90.1.1")), hostKey: DirectIdentity().publicKey)
        let carrier = DirectCarrier(identity: DirectIdentity(), resolver: resolver, routes: Offline())
        await #expect(throws: DirectCarrierError.routeUnavailable(.noTunnel)) {
            try await carrier.connect(to: LinkPeer(hostID: "h", hints: resolver.hints(for: endpoint)))
        }
        await #expect(throws: DirectCarrierError.noEndpoint) {
            try await carrier.connect(to: LinkPeer(hostID: "h"))
        }
    }
}
