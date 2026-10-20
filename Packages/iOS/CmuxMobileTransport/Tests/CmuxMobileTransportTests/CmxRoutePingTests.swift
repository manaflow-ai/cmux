import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileTransport

@Test func pingReportsReachableWithLatencyForLiveListener() async throws {
    let listener = try PingTestListener()
    let port = try await listener.start()
    defer { listener.stop() }

    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: Int(port))
    )

    let result = await CmxNetworkRoutePinger().ping(route, timeoutNanoseconds: 5_000_000_000)

    guard case let .reachable(latency) = result else {
        Issue.record("expected .reachable, got \(result)")
        return
    }
    #expect(latency >= 0)
}

@Test func pingReportsRefusedWhenNothingListens() async throws {
    // Bind then release a port so the OS gives an immediate refusal on dial.
    let listener = try PingTestListener()
    let port = try await listener.start()
    await listener.stopAndWaitForCancellation()

    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: Int(port))
    )

    let result = await CmxNetworkRoutePinger().ping(route, timeoutNanoseconds: 5_000_000_000)

    #expect(result == .refused)
    #expect(result.isReachable)      // an RST proves the host is reachable
    #expect(!result.isListening)     // but nothing accepted on the port
}

@Test func pingReportsUnsupportedRouteForNonHostPortEndpoint() async throws {
    let route = try CmxAttachRoute(
        id: "iroh",
        kind: .iroh,
        endpoint: .peer(
            id: String(repeating: "e", count: 64),
            relayHint: nil,
            directAddrs: [],
            relayURL: nil
        )
    )

    let result = await CmxNetworkRoutePinger().ping(route)

    #expect(result == .unsupportedRoute)
}
