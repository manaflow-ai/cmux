import Foundation
import Testing
@testable import CMUXMobileCore
@testable import CmuxMobileIrohTransport

// MARK: - Fast unit tests (no networking)

@Test func factoryAdvertisesOnlyIroh() {
    let factory = CmxIrohByteTransportFactory()
    #expect(factory.supportedKinds == [.iroh])
}

@Test func factoryRejectsNonIrohRoute() throws {
    let factory = CmxIrohByteTransportFactory()
    let route = try CmxAttachRoute(
        id: "r1",
        kind: .tailscale,
        endpoint: .hostPort(host: "100.64.0.1", port: 8080)
    )
    #expect(throws: CmxIrohByteTransportError.unsupportedRouteKind(.tailscale)) {
        _ = try factory.makeTransport(for: route)
    }
}

@Test func connectFailureKindMapsFromStableFFIValues() {
    #expect(CmxIrohConnectFailureKind(rawKind: 3) == .timedOut)
    #expect(CmxIrohConnectFailureKind(rawKind: 4) == .peerUnreachable)
    #expect(CmxIrohConnectFailureKind(rawKind: 2) == .bindFailed)
    #expect(CmxIrohConnectFailureKind(rawKind: 5) == .connectionLost)
    #expect(CmxIrohConnectFailureKind(rawKind: 6) == .connectionLost)
    #expect(CmxIrohConnectFailureKind(rawKind: 1) == .generic)
    #expect(CmxIrohConnectFailureKind(rawKind: 99) == .generic)
}

// MARK: - Loopback integration (real iroh QUIC, both ends real Swift)

@Test func loopbackDialRoundTripsBytesAndClosesCleanly() async throws {
    // Host side: a relay-less listener (the Mac's accept lane).
    let listener = CmxIrohByteListener(enableRelay: false)
    try await listener.start()

    guard let routeJSON = await listener.routeJSON() else {
        Issue.record("listener produced no route JSON")
        await listener.close()
        return
    }
    let (peerID, directAddrs) = try parsePeerRoute(routeJSON)
    #expect(!peerID.isEmpty)
    #expect(!directAddrs.isEmpty, "a relay-less listener must publish direct addrs to dial")

    // Accept one connection and echo every chunk until the dialer closes.
    let echo = Task {
        do {
            let stream = try await listener.accept(timeoutMilliseconds: 10_000)
            while let chunk = try await stream.receive() {
                if chunk.isEmpty { break }
                try await stream.send(chunk)
            }
            await stream.close()
        } catch {
            // The dialer closing mid-receive surfaces here; expected end state.
        }
    }

    // Phone side: dial the listener by EndpointId + direct addrs.
    let transport = CmxIrohByteTransport(
        endpointID: peerID,
        relayURL: nil,
        directAddrs: directAddrs,
        enableRelay: false,
        connectTimeoutMilliseconds: 10_000
    )
    try await transport.connect()
    let payload = Data("cmux-iroh-loopback-roundtrip".utf8)
    try await transport.send(payload)
    let echoed = try await transport.receive()
    #expect(echoed == payload)
    await transport.close()

    await echo.value
    await listener.close()
}

// MARK: - Test helpers

/// Parses a listener's `route_json` into (EndpointId, direct addrs).
private func parsePeerRoute(_ json: String) throws -> (id: String, directAddrs: [String]) {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    guard
        let root = object as? [String: Any],
        let endpoint = root["endpoint"] as? [String: Any],
        let id = endpoint["id"] as? String,
        let addrs = endpoint["direct_addrs"] as? [String]
    else {
        throw LoopbackTestError.malformedRouteJSON(json)
    }
    return (id, addrs)
}

private enum LoopbackTestError: Error {
    case malformedRouteJSON(String)
}
