import CMUXMobileCore
import Foundation
import Testing

@Test
func v3RoutePreservesPeerAndAddressHintsWithoutIrohShape() throws {
    let identity = try CmxV3PeerIdentity(
        peerID: "12D3KooWTestPeer",
        addresses: ["/ip4/203.0.113.10/tcp/4001"]
    )
    let route = try CmxAttachRoute(
        id: "libp2p_v3",
        kind: .v3,
        endpoint: .v3Peer(identity),
        priority: 1
    )
    let data = try JSONEncoder().encode(route)
    let decoded = try JSONDecoder().decode(CmxAttachRoute.self, from: data)
    #expect(decoded == route)
    #expect(String(decoding: data, as: UTF8.self).contains("v3_peer"))
    #expect(!String(decoding: data, as: UTF8.self).contains("iroh"))
}

@Test
func v3RouteRejectsMalformedOrOversizedDirectoryHints() throws {
    #expect(throws: CmxV3PeerIdentity.Error.invalidAddress) {
        try CmxV3PeerIdentity(peerID: "peer", addresses: [String(repeating: "x", count: 2049)])
    }
    #expect(throws: CmxV3PeerIdentity.Error.invalidPeerID) {
        try CmxV3PeerIdentity(peerID: "", addresses: [])
    }
    let tooMany = Array(repeating: "/ip4/203.0.113.10/tcp/4001", count: 33)
    #expect(throws: CmxV3PeerIdentity.Error.invalidAddress) {
        try CmxV3PeerIdentity(peerID: "peer", addresses: tooMany)
    }
    let encoded: [String: Any] = ["peer_id": "peer", "addresses": tooMany]
    let data = try JSONSerialization.data(withJSONObject: encoded)
    #expect(throws: CmxV3PeerIdentity.Error.invalidAddress) {
        try JSONDecoder().decode(CmxV3PeerIdentity.self, from: data)
    }
    #expect(throws: CmxV3PeerIdentity.Error.invalidPeerID) {
        try CmxV3PeerIdentity(peerID: " peer ", addresses: [])
    }
}
