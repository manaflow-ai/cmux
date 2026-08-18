import Foundation
import Testing
@testable import CMUXMobileCore

@Test func legacyTailscaleRouteNormalizesToTheStableTCPRoute() throws {
    let legacy = try CmxAttachRoute(
        id: "mac-private",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.10.2", port: 58_465),
        priority: 7
    )

    let normalized = try legacy.normalizedForStableTransport()

    #expect(normalized.kind == .tcp)
    #expect(normalized.endpoint == legacy.endpoint)
    #expect(normalized.id == legacy.id)
    #expect(normalized.priority == legacy.priority)
}

@Test func nativeIrohRouteCannotEnterTheStableTCPTransport() throws {
    let legacy = try CmxAttachRoute(
        id: "iroh-peer",
        kind: .iroh,
        endpoint: .peer(
            id: String(repeating: "a", count: 64),
            relayHint: nil,
            directAddrs: [],
            relayURL: nil
        )
    )

    #expect(throws: CmxStableTransportRouteError.nativeTransportUnavailable(.iroh)) {
        _ = try legacy.normalizedForStableTransport()
    }
}

@Test func stableTCPRoutePreservesItsIdentityAndEndpoint() throws {
    let route = try CmxAttachRoute(
        id: "tcp",
        kind: .tcp,
        endpoint: .hostPort(host: "192.168.1.20", port: 58_465),
        priority: -3
    )

    #expect(try route.normalizedForStableTransport() == route)
}
