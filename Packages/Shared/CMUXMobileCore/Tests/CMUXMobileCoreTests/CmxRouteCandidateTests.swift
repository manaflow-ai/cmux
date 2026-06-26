import Foundation
import Testing
@testable import CMUXMobileCore

/// Tests the pure route-candidate merge model (#6351): proximity classification,
/// endpoint dedup, and the union/freshness/proximity ranking the phone uses to
/// try a paired Mac's routes in order.
@Suite struct CmxRouteCandidateTests {
    private func hostPort(
        _ host: String,
        port: Int = 50_000,
        kind: CmxAttachTransportKind = .tailscale,
        id: String = "r",
        priority: Int = 0
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: id, kind: kind, endpoint: .hostPort(host: host, port: port), priority: priority)
    }

    private func peer(_ id: String) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "p-\(id)",
            kind: .iroh,
            endpoint: .peer(id: id, relayHint: nil, directAddrs: [], relayURL: nil)
        )
    }

    private func candidate(
        _ route: CmxAttachRoute,
        _ source: CmxRouteSource = .registry,
        at seconds: TimeInterval = 100
    ) -> CmxRouteCandidate {
        CmxRouteCandidate(route: route, source: source, lastSeenAt: Date(timeIntervalSinceReferenceDate: seconds))
    }

    // MARK: - Proximity classification

    @Test func classifiesLoopbackAddresses() {
        #expect(CmxRouteProximity.classify(.hostPort(host: "127.0.0.1", port: 1)) == .loopback)
        #expect(CmxRouteProximity.classify(.hostPort(host: "127.255.255.254", port: 1)) == .loopback)
        #expect(CmxRouteProximity.classify(.hostPort(host: "::1", port: 1)) == .loopback)
        #expect(CmxRouteProximity.classify(.hostPort(host: "[::1]", port: 1)) == .loopback)
        #expect(CmxRouteProximity.classify(.hostPort(host: "localhost", port: 1)) == .loopback)
        #expect(CmxRouteProximity.classify(.hostPort(host: "db.localhost", port: 1)) == .loopback)
    }

    @Test func classifiesLanAddresses() {
        #expect(CmxRouteProximity.classify(.hostPort(host: "10.0.0.5", port: 1)) == .lan)
        #expect(CmxRouteProximity.classify(.hostPort(host: "172.16.0.1", port: 1)) == .lan)
        #expect(CmxRouteProximity.classify(.hostPort(host: "172.31.255.1", port: 1)) == .lan)
        #expect(CmxRouteProximity.classify(.hostPort(host: "192.168.1.1", port: 1)) == .lan)
        #expect(CmxRouteProximity.classify(.hostPort(host: "169.254.1.2", port: 1)) == .lan)
        #expect(CmxRouteProximity.classify(.hostPort(host: "fe80::1", port: 1)) == .lan)
        #expect(CmxRouteProximity.classify(.hostPort(host: "fc00::1", port: 1)) == .lan)
        #expect(CmxRouteProximity.classify(.hostPort(host: "fd12:3456::1", port: 1)) == .lan)
    }

    @Test func classifiesTailnetAddresses() {
        #expect(CmxRouteProximity.classify(.hostPort(host: "100.64.0.1", port: 1)) == .tailnet)
        #expect(CmxRouteProximity.classify(.hostPort(host: "100.127.255.255", port: 1)) == .tailnet)
        #expect(CmxRouteProximity.classify(.hostPort(host: "100.82.214.112", port: 1)) == .tailnet)
        #expect(CmxRouteProximity.classify(.hostPort(host: "node.tail137216.ts.net", port: 1)) == .tailnet)
        #expect(CmxRouteProximity.classify(.hostPort(host: "fd7a:115c:a1e0::4b36:d670", port: 1)) == .tailnet)
    }

    @Test func classifiesRelayAddresses() {
        // Public IP literal: dialable but not local/tailnet.
        #expect(CmxRouteProximity.classify(.hostPort(host: "8.8.8.8", port: 1)) == .relay)
        // 100.0.0.0/8 outside the 100.64/10 CGNAT range is not a tailnet IP.
        #expect(CmxRouteProximity.classify(.hostPort(host: "100.0.0.1", port: 1)) == .relay)
        #expect(CmxRouteProximity.classify(.hostPort(host: "100.128.0.1", port: 1)) == .relay)
        // 172.x outside 16..31 is not RFC1918 private.
        #expect(CmxRouteProximity.classify(.hostPort(host: "172.15.0.1", port: 1)) == .relay)
        #expect(CmxRouteProximity.classify(.hostPort(host: "172.32.0.1", port: 1)) == .relay)
        // A general hostname needs DNS.
        #expect(CmxRouteProximity.classify(.hostPort(host: "example.com", port: 1)) == .relay)
        // iroh peer and websocket URL transports are relay-class.
        #expect(CmxRouteProximity.classify(.peer(id: "abc", relayHint: nil, directAddrs: [], relayURL: nil)) == .relay)
        #expect(CmxRouteProximity.classify(.url("wss://relay.example/ws")) == .relay)
    }

    @Test func classifiesEmptyHostAsUnknown() {
        #expect(CmxRouteProximity.classify(.hostPort(host: "", port: 1)) == .unknown)
        #expect(CmxRouteProximity.classify(.hostPort(host: "   ", port: 1)) == .unknown)
    }

    // MARK: - Endpoint dedup keys

    @Test func dedupKeyIsCaseAndBracketInsensitive() {
        #expect(
            CmxAttachEndpoint.hostPort(host: "FE80::1", port: 5).routeDedupKey
                == CmxAttachEndpoint.hostPort(host: "[fe80::1]", port: 5).routeDedupKey
        )
        #expect(
            CmxAttachEndpoint.hostPort(host: "Host.TS.NET", port: 5).routeDedupKey
                == CmxAttachEndpoint.hostPort(host: "host.ts.net", port: 5).routeDedupKey
        )
    }

    @Test func dedupKeyDistinguishesPort() {
        #expect(
            CmxAttachEndpoint.hostPort(host: "h", port: 5).routeDedupKey
                != CmxAttachEndpoint.hostPort(host: "h", port: 6).routeDedupKey
        )
    }

    // MARK: - Merge: dedup

    @Test func mergedEmptyInputIsEmpty() {
        #expect(CmxRouteCandidateSet().merged().isEmpty)
    }

    @Test func mergedDedupsSameEndpointKeepingFresher() throws {
        let older = candidate(try hostPort("192.168.1.5"), .localCache, at: 100)
        let newer = candidate(try hostPort("192.168.1.5"), .localCache, at: 200)
        let merged = CmxRouteCandidateSet([older, newer]).merged()
        #expect(merged.count == 1)
        #expect(merged.first?.lastSeenAt == Date(timeIntervalSinceReferenceDate: 200))
    }

    @Test func mergedDedupTieBreaksOnSourceAuthority() throws {
        // Same endpoint, equally fresh: the authoritative registry wins over the
        // possibly-stale local cache.
        let cache = candidate(try hostPort("192.168.1.5"), .localCache, at: 100)
        let registry = candidate(try hostPort("192.168.1.5"), .registry, at: 100)
        let merged = CmxRouteCandidateSet([cache, registry]).merged()
        #expect(merged.count == 1)
        #expect(merged.first?.source == .registry)
    }

    @Test func mergedDedupsPeerById() throws {
        let qr = candidate(try peer("nodeabc"), .qr, at: 100)
        let registry = candidate(try peer("nodeabc"), .registry, at: 100)
        #expect(CmxRouteCandidateSet([qr, registry]).merged().count == 1)
        let other = candidate(try peer("nodexyz"), .qr, at: 100)
        #expect(CmxRouteCandidateSet([qr, other]).merged().count == 2)
    }

    // MARK: - Merge: ranking

    @Test func mergedRanksLanBeforeTailnetBeforeRelayOnDevice() throws {
        let relay = candidate(try hostPort("8.8.8.8"))
        let tailnet = candidate(try hostPort("100.96.0.9"))
        let lan = candidate(try hostPort("192.168.1.5"))
        let merged = CmxRouteCandidateSet([relay, tailnet, lan]).merged(preferLoopback: false)
        #expect(merged.map(\.proximity) == [.lan, .tailnet, .relay])
    }

    @Test func mergedRanksLoopbackLastOnDeviceFirstOnSimulator() throws {
        let loop = candidate(try hostPort("127.0.0.1"))
        let lan = candidate(try hostPort("192.168.1.5"))
        #expect(CmxRouteCandidateSet([loop, lan]).merged(preferLoopback: false).map(\.proximity) == [.lan, .loopback])
        #expect(CmxRouteCandidateSet([loop, lan]).merged(preferLoopback: true).map(\.proximity) == [.loopback, .lan])
    }

    @Test func mergedPrefersFresherWithinSameTier() throws {
        let older = candidate(try hostPort("192.168.1.5", id: "old"), .localCache, at: 100)
        let newer = candidate(try hostPort("192.168.1.9", id: "new"), .localCache, at: 200)
        let merged = CmxRouteCandidateSet([older, newer]).merged()
        #expect(merged.first?.route.id == "new")
    }

    @Test func mergedTieBreaksOnRoutePriorityWithinTier() throws {
        let high = candidate(try hostPort("192.168.1.9", id: "hi", priority: 10))
        let low = candidate(try hostPort("192.168.1.5", id: "lo", priority: 0))
        let merged = CmxRouteCandidateSet([high, low]).merged()
        #expect(merged.first?.route.id == "lo") // lower priority value tried first
    }

    @Test func mergedRoutesProjectsToRoutesInRankedOrder() throws {
        let relay = candidate(try hostPort("8.8.8.8", id: "relay"))
        let lan = candidate(try hostPort("192.168.1.5", id: "lan"))
        #expect(CmxRouteCandidateSet([relay, lan]).mergedRoutes().map(\.id) == ["lan", "relay"])
    }

    @Test func mergedRespectsMaxCandidatesKeepingBestRanked() throws {
        let relay = candidate(try hostPort("8.8.8.8", id: "relay"))
        let tailnet = candidate(try hostPort("100.96.0.9", id: "tn"))
        let lan = candidate(try hostPort("192.168.1.5", id: "lan"))
        let merged = CmxRouteCandidateSet([relay, tailnet, lan]).merged(maxCandidates: 2)
        #expect(merged.count == 2)
        #expect(merged.map(\.proximity) == [.lan, .tailnet]) // dropped the relay
    }

    // MARK: - init(routes:source:lastSeenAt:) and union

    @Test func routesInitializerStampsSourceAndDate() throws {
        let date = Date(timeIntervalSinceReferenceDate: 42)
        let set = CmxRouteCandidateSet(routes: [try hostPort("10.0.0.1")], source: .qr, lastSeenAt: date)
        #expect(set.candidates.count == 1)
        #expect(set.candidates.first?.source == .qr)
        #expect(set.candidates.first?.lastSeenAt == date)
    }

    @Test func unionedMergesCandidatesFromBothSets() throws {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let registry = CmxRouteCandidateSet(routes: [try hostPort("100.96.0.9", id: "tn")], source: .registry, lastSeenAt: date)
        let cache = CmxRouteCandidateSet(routes: [try hostPort("192.168.1.5", id: "lan")], source: .localCache, lastSeenAt: date)
        let merged = registry.unioned(with: cache).merged()
        #expect(merged.count == 2)
        #expect(merged.map(\.proximity) == [.lan, .tailnet]) // LAN closest, tried first
    }
}
