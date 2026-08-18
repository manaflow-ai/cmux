/// Why a cached relay policy could not be used at resolution time.
public enum PeerRelayPolicyDenialReason: Equatable, Sendable {
    /// No policy record is cached on this device.
    case missing

    /// The cached policy reached its signed expiry.
    case expired

    /// The cached record contradicts the monotonic rollback floor.
    case rollback

    /// The cached record failed signature, shape, or storage validation.
    case invalid
}

/// The fail-closed outcome of resolving the cached relay policy.
///
/// Every rejection class resolves to ``directOnly(_:)`` with zero relays.
/// There is no state in which unverified relay origins are used.
public enum PeerRelayPolicyResolution: Equatable, Sendable {
    /// A root-verified, unexpired, rollback-checked policy.
    case verified(PeerRelayPolicy)

    /// No usable policy; connect with direct paths only, no relays.
    case directOnly(PeerRelayPolicyDenialReason)

    /// The verified policy, when one is available.
    public var policy: PeerRelayPolicy? {
        switch self {
        case .verified(let policy): policy
        case .directOnly: nil
        }
    }

    /// The relay catalog to use; empty for every denial class.
    public var relays: [PeerRelayDescriptor] {
        switch self {
        case .verified(let policy): policy.relays
        case .directOnly: []
        }
    }

    /// True when no relays may be configured.
    public var isDirectOnly: Bool {
        switch self {
        case .verified: false
        case .directOnly: true
        }
    }
}
