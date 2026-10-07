/// What a link key certificate binds to the install key (b6-pairing.md section 2).
public enum LinkPurpose: String, Hashable, Sendable, Codable, CaseIterable {
    /// B4's Noise IK static X25519 key.
    case direct
    /// The WireGuard overlay X25519 key (transport.md section 8).
    case wg
    /// One WebRTC session's DTLS certificate fingerprint (B2), at most 15 minutes.
    case dtls

    /// The longest lifetime the owner accepts, in milliseconds.
    public var maxLifetimeMilliseconds: Int64 {
        switch self {
        case .direct, .wg: 90 * 86_400_000
        case .dtls: 15 * 60_000
        }
    }
}
