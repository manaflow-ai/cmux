import Foundation

/// A v3 libp2p peer and its directory addresses.
/// Addresses are untrusted routing hints. Noise/QUIC peer identity and the
/// server-issued grant remain authoritative during connection setup.
public struct CmxV3PeerIdentity: Codable, Equatable, Sendable {
    public let peerID: String
    public let addresses: [String]

    public init(peerID: String, addresses: [String]) throws {
        guard !peerID.isEmpty, peerID.utf8.count <= 256,
              peerID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { throw Error.invalidPeerID }
        guard addresses.count <= 32,
              addresses.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 2048 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) })
        else { throw Error.invalidAddress }
        self.peerID = peerID
        self.addresses = addresses
    }

    private enum CodingKeys: String, CodingKey { case peerID = "peer_id"; case addresses }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(peerID: container.decode(String.self, forKey: .peerID),
                      addresses: container.decode([String].self, forKey: .addresses))
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidPeerID
        case invalidAddress
    }
}
