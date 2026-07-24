/// One peer identity from the authenticated local Tailscale status snapshot.
public struct CmxTailscalePeerRecord: Equatable, Sendable {
    /// Tailscale's stable identifier for the peer when the client supplied it.
    public let stableID: String?
    /// The normalized fully qualified MagicDNS name without a trailing dot.
    public let dnsName: String
    /// Every numeric peer address carried by the same status record.
    public let addresses: [CmxTailscalePeerAddress]
    /// The deterministic numeric transport target, preferring IPv4 over IPv6.
    public let preferredAddress: CmxTailscalePeerAddress
    /// Whether this record came from the status snapshot's `Self` entry.
    public let isLocalDevice: Bool
}
