import CMUXMobileCore
import CmuxV3Native
import CryptoKit
import Foundation
import Testing
@testable import CmuxV3Transport

private func grant(source: String, destination: String, key: Curve25519.Signing.PrivateKey) throws -> String {
    func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg":"EdDSA","typ":"cmux-v3-grant+jwt","kid":"test"])
    let claims: [String: Any] = ["iss":"cmux-transport-v3", "aud":destination, "sub":source,
        "team_id":"a", "action":"connect", "policy_revision":1, "iat":now, "exp":now+60,
        "lease":["offline":["mode":"bounded","seconds":60],"renew_every_seconds":10]]
    let payload = try JSONSerialization.data(withJSONObject: claims)
    let message = "\(base64(header)).\(base64(payload))"
    return "\(message).\(base64(try key.signature(for: Data(message.utf8))))"
}

private actor Count {
    var value = 0
    func increment() { value += 1 }
}

@Test(.timeLimit(.minutes(1)))
func generatedSwiftCallsRealRustTransportThroughByteSeam() async throws {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 61, count: 32))
    let keys = ["test": key.publicKey.rawRepresentation]
    let a = try await NativeEndpoint.create(seed: Data(repeating: 62, count: 32), team: "a", authorityKeys: keys)
    let b = try await NativeEndpoint.create(seed: Data(repeating: 63, count: 32), team: "a", authorityKeys: keys)
    defer { a.close(); b.close() }
    let address = try await b.listen(address: "/ip4/127.0.0.1/udp/0/quic-v1", operation: CmuxV3Native.Operation())
    let peer = b.peerId()
    let token = try grant(source: a.peerId(), destination: peer, key: key)
    let count = Count()
    let transport = V3ByteTransport { operation in
        await count.increment()
        return try await a.open(peerId: peer, address: "\(address)/p2p/\(peer)", grant: token,
                                relayGrant: nil, lane: LaneDescriptor(kind: 0, resource: nil, cursor: nil), operation: operation)
    }
    async let accepted = b.accept(operation: CmuxV3Native.Operation())
    async let first: Void = transport.connect()
    async let second: Void = transport.connect()
    try await first
    try await second
    let incoming = try await accepted
    #expect(incoming.peerId == a.peerId())
    #expect(await count.value == 1)
    let server = V3ByteTransport(stream: incoming.stream)
    let observer = await transport.transportClosureObservation()
    #expect(observer != nil)
    let payload = Data(repeating: 7, count: 128 * 1024)
    async let write: Void = transport.send(payload)
    var received = Data()
    while received.count < payload.count {
        received.append(try #require(await server.receive()))
    }
    try await write
    #expect(received == payload)
    try await server.send(Data("reply".utf8))
    #expect(try await transport.receive() == Data("reply".utf8))
    observer?.cancel()
    #expect(await transport.isTransportClosed() == false)
    let read = Task { try await transport.receive() }
    read.cancel()
    do { _ = try await read.value; Issue.record("cancelled read returned bytes") } catch {}
    await transport.close()
    #expect(await transport.isTransportClosed())
    await server.close()
}

@Test(.timeLimit(.minutes(1)))
func closingDuringEstablishmentRetiresLateStream() async throws {
    let operationStarted = AsyncStream<Void>.makeStream()
    let transport = V3ByteTransport { operation in
        operationStarted.continuation.yield(())
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 64, count: 32))
        let endpoint = try await NativeEndpoint.create(seed: Data(repeating: 65, count: 32), team: "a",
            authorityKeys: ["test":key.publicKey.rawRepresentation])
        defer { endpoint.close() }
        return try await endpoint.accept(operation: operation).stream
    }
    let connecting = Task { try await transport.connect() }
    for await _ in operationStarted.stream { break }
    await transport.close()
    do { try await connecting.value; Issue.record("closed transport connected") } catch {}
    #expect(await transport.isTransportClosed())
}
