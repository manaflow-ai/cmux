/// The exact local binding and bounded peer set required by one app runtime.
///
/// Echoed verbatim by connectivity v3 and scoped registration; wire format is
/// unchanged from the previous transport.
public struct PeerDiscoveryScope: Codable, Equatable, Sendable {
    /// The caller's own binding, preserved independently from the peer selector.
    public struct LocalBinding: Codable, Equatable, Sendable {
        public let deviceID: String
        public let appInstanceID: String
        public let tag: String
        public let platform: PeerPlatform

        private enum CodingKeys: String, CodingKey {
            case deviceID = "device_id"
            case appInstanceID = "app_instance_id"
            case tag
            case platform
        }
    }

    /// The bounded opposite-platform bindings visible to this runtime.
    public struct PeerBindings: Codable, Equatable, Sendable {
        public let platform: PeerPlatform
        public let tags: [String]?
        public let pairingEnabled: Bool?

        private enum CodingKeys: String, CodingKey {
            case platform
            case tags
            case pairingEnabled = "pairing_enabled"
        }
    }

    public let localBinding: LocalBinding
    public let peerBindings: PeerBindings

    private enum CodingKeys: String, CodingKey {
        case localBinding = "local_binding"
        case peerBindings = "peer_bindings"
    }

    /// Creates the canonical scope echoed by connectivity v3.
    ///
    /// Peer tags are lowercased, deduplicated by rejection, and sorted so the
    /// case-insensitive compatibility contract is stable across implementations.
    public init(
        deviceID: String,
        appInstanceID: String,
        tag: String,
        platform: PeerPlatform,
        peerPlatform: PeerPlatform,
        peerTags: [String]? = nil,
        peerPairingEnabled: Bool? = nil
    ) throws {
        guard Self.isScopeUUID(deviceID),
              Self.isScopeUUID(appInstanceID),
              Self.isSafeTag(tag),
              platform != peerPlatform,
              peerTags.map({ (1 ... 8).contains($0.count) }) ?? true,
              peerTags?.allSatisfy(Self.isSafeTag) ?? true else {
            throw PeerDiscoveryScopeError.invalidScope
        }
        let canonicalPeerTags = peerTags?.map { $0.lowercased() }
        guard canonicalPeerTags.map({ Set($0).count == $0.count }) ?? true else {
            throw PeerDiscoveryScopeError.invalidScope
        }
        localBinding = LocalBinding(
            deviceID: deviceID,
            appInstanceID: appInstanceID,
            tag: tag,
            platform: platform
        )
        peerBindings = PeerBindings(
            platform: peerPlatform,
            tags: canonicalPeerTags?.sorted(),
            pairingEnabled: peerPairingEnabled
        )
    }

    /// Decodes and validates a canonical discovery scope.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let local = try container.decode(LocalBinding.self, forKey: .localBinding)
        let peers = try container.decode(PeerBindings.self, forKey: .peerBindings)
        try self.init(
            deviceID: local.deviceID,
            appInstanceID: local.appInstanceID,
            tag: local.tag,
            platform: local.platform,
            peerPlatform: peers.platform,
            peerTags: peers.tags,
            peerPairingEnabled: peers.pairingEnabled
        )
    }

    private static func isScopeUUID(_ value: String) -> Bool {
        guard PeerBrokerWire.isCanonicalUUID(value), value.count == 36 else {
            return false
        }
        let characters = Array(value.utf8)
        guard (49 ... 56).contains(characters[14]),
              [56, 57, 97, 98].contains(characters[19]) else { return false }
        return true
    }

    private static func isSafeTag(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 95].contains(byte)
        }
    }
}

public enum PeerDiscoveryScopeError: Error, Equatable, Sendable {
    case invalidScope
}
