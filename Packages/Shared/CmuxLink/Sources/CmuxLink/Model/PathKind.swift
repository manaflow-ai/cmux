/// How a link's bytes reach the peer, in the default policy order
/// (plans/cmux-next/ios-next/PLAN.md section 1): a direct address, a WebRTC
/// peer-to-peer path, a TURN relay, then the Durable Object relay.
public enum PathKind: String, Sendable, Hashable, CaseIterable, Codable {
    /// A dialed address (LAN, Tailscale, WireGuard) with no rendezvous.
    case direct
    /// WebRTC ICE found a host or server-reflexive pair.
    case p2p
    /// WebRTC through a TURN relay (Cloudflare Realtime).
    case turn
    /// The host's Durable Object relay. Control-sized traffic only.
    case relay

    /// Relayed paths get a badge on interactive surfaces (transport.md 1.1).
    public var isRelayed: Bool {
        self == .turn || self == .relay
    }
}
