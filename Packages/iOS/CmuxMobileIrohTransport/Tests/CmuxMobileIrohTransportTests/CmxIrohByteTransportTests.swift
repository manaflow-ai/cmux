import Foundation
import Testing
internal import CmuxIrohFFI
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

// MARK: - Loopback integration (real iroh QUIC, relay-less, direct-addr dial)

@Test func loopbackDialRoundTripsBytesAndClosesCleanly() async throws {
    guard let serverKey = CmxIrohByteTransport.generateSecretKey() else {
        Issue.record("failed to generate server secret key")
        return
    }

    // Bind a relay-less listener and read its dial-able route.
    let serverOutcome = CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
        serverKey.withUnsafeBufferPointer { keyBuffer in
            cmux_iroh_endpoint_bind(keyBuffer.baseAddress, keyBuffer.count, false, true, kindPtr, errBuf, cap)
        }
    }
    guard let server = serverOutcome.result else {
        Issue.record("failed to bind listener: \(serverOutcome.message)")
        return
    }
    defer { cmux_iroh_endpoint_close(server) }

    let (peerID, directAddrs) = try serverRoute(server)
    #expect(!peerID.isEmpty)
    #expect(!directAddrs.isEmpty, "a relay-less listener must publish direct addrs to dial")

    // Echo every received chunk back until the dialer closes the stream.
    let serverBox = CmxIrohUnsafeBox(server)
    let echoTask = Task.detached(priority: .userInitiated) {
        runEchoServerOnce(serverBox.value)
    }

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
    await echoTask.value
}

// MARK: - Test helpers

/// Parses an endpoint's `route_json` into (EndpointId, direct addrs).
private func serverRoute(_ endpoint: OpaquePointer) throws -> (id: String, directAddrs: [String]) {
    guard let json = CmxIrohByteTransport.takeString(cmux_iroh_endpoint_route_json(endpoint)) else {
        throw LoopbackTestError.noRouteJSON
    }
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    guard
        let root = object as? [String: Any],
        let endpointObject = root["endpoint"] as? [String: Any],
        let id = endpointObject["id"] as? String,
        let addrs = endpointObject["direct_addrs"] as? [String]
    else {
        throw LoopbackTestError.malformedRouteJSON(json)
    }
    return (id, addrs)
}

/// Accepts one connection and echoes every chunk until the stream ends.
private func runEchoServerOnce(_ server: OpaquePointer) {
    let accept = CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
        cmux_iroh_endpoint_accept(server, 10_000, kindPtr, errBuf, cap)
    }
    guard let connection = accept.result else { return }
    defer { cmux_iroh_connection_close(connection) }

    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let received = CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
            buffer.withUnsafeMutableBufferPointer { bufferPointer in
                Int(cmux_iroh_connection_recv(
                    connection, bufferPointer.baseAddress, bufferPointer.count, 0, kindPtr, errBuf, cap
                ))
            }
        }
        let count = received.result
        if count <= 0 { break }
        let sent = buffer.withUnsafeBufferPointer { bufferPointer in
            CmxIrohByteTransport.withErrorBuffer { kindPtr, errBuf, cap in
                cmux_iroh_connection_send(
                    connection, bufferPointer.baseAddress, count, 0, kindPtr, errBuf, cap
                )
            }
        }
        if sent.result != 0 { break }
    }
}

private enum LoopbackTestError: Error {
    case noRouteJSON
    case malformedRouteJSON(String)
}
