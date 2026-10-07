/// A fixed key-to-install map (tests, and a host with a static trust list).
public struct WireGuardPinnedAuthorizer: WireGuardAuthorizer {
    public let peers: [WireGuardPublicKey: String]

    public init(peers: [WireGuardPublicKey: String]) {
        self.peers = peers
    }

    public func authorize(peer: WireGuardPublicKey) async -> WireGuardAuthorizedPeer? {
        peers[peer].map(WireGuardAuthorizedPeer.init(installID:))
    }
}
