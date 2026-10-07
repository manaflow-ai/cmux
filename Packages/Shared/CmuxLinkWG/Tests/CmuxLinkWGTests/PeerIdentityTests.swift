import CmuxLink
import CmuxLinkWG
import Foundation
import Testing

@Suite("WebRTC-WG peer identity", .serialized)
struct PeerIdentityTests {
    @Test("both ends report the WireGuard key they proved; the host adds the authorized install")
    func identities() async throws {
        let pair = try await TransportPair.connect()
        let host = try #require(pair.host.peerIdentity)
        let dialer = try #require(pair.dialer.peerIdentity)
        #expect(host == LinkPeerIdentity(carrier: .webrtcWireGuard, keyKind: .x25519,
                                         publicKey: pair.host.remoteKey.rawRepresentation, install: "device-1"))
        #expect(dialer == LinkPeerIdentity(carrier: .webrtcWireGuard, keyKind: .x25519,
                                           publicKey: pair.dialer.remoteKey.rawRepresentation))
        #expect(!host.sameKey(as: dialer))
        await pair.shutdown()
    }
}
