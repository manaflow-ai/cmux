import CmuxWireGuard
import CmuxWireGuardPairing
import Foundation
import Testing

@Suite struct WireGuardTunnelTests {
    /// A host and a phone tunnel on loopback: the phone dials the host over
    /// WireGuard and bytes cross both ways, then end of stream propagates.
    @Test func tunneledStreamCarriesBytesBothWays() async throws {
        let hostKey = WireGuardKey()
        let phoneKey = WireGuardKey()
        let psk = WireGuardKey(randomPresharedKey: ())
        let host = try WireGuardTunnel(address: "10.77.0.1", privateKey: hostKey, peers: [
            .init(publicKey: phoneKey.publicKey, presharedKey: psk, allowedIPs: ["10.77.0.2/32"]),
        ])
        defer { host.stop() }
        let port = try #require(host.status().listenPort)
        let phone = try WireGuardTunnel(address: "10.77.0.2", privateKey: phoneKey, peers: [
            .init(publicKey: hostKey.publicKey, presharedKey: psk, endpoint: "127.0.0.1:\(port)",
                  allowedIPs: ["10.77.0.1/32"], keepaliveSeconds: 25),
        ])
        defer { phone.stop() }

        let listener = try host.listen(port: 7300)
        async let accepted = listener.accept()
        let client = try await phone.connect(host: "10.77.0.1", port: 7300)
        let (server, peer) = try await accepted
        #expect(peer == "10.77.0.2")

        try await client.write(Data("hello\n".utf8))
        let line = try await server.read()
        #expect(line == Data("hello\n".utf8))

        let payload = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try await server.write(payload)
        server.shutdownWrite()
        var received = Data()
        while let chunk = try await client.read() { received.append(chunk) }
        #expect(received == payload)

        let status = host.status()
        #expect(status.peer(phoneKey.publicKey)?.lastHandshake != nil)
        client.close()
        server.close()
        listener.close()
    }
}
