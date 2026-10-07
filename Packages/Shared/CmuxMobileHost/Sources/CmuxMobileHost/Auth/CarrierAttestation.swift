public import CmuxLink

/// A peer identity a carrier established itself (B4 pinned device key, B2
/// signaling `from` rewritten by `HostDO`). Optional: when present it must
/// name the same install as the hello proof.
public struct CarrierAttestation: Hashable, Sendable {
    public var install: String
    public var carrier: String

    public init(install: String, carrier: String) {
        self.install = install
        self.carrier = carrier
    }

    /// A key the carrier proved that no install owns: never matches a hello.
    public static func unresolved(carrier: String) -> CarrierAttestation {
        CarrierAttestation(install: "", carrier: carrier)
    }

    /// The attestation for a session's authenticated peer: the install the
    /// carrier named, else the one `resolver` maps the key to. Nil when the
    /// carrier authenticates no one (loopback) or no resolver is configured
    /// for a key without an install.
    public static func make(identity: LinkPeerIdentity?, resolver: (any CarrierKeyResolver)?) async -> CarrierAttestation? {
        guard let identity else { return nil }
        let carrier = identity.carrier.rawValue
        if let install = identity.install { return CarrierAttestation(install: install, carrier: carrier) }
        guard let resolver else { return nil }
        guard let install = await resolver.install(for: identity) else { return .unresolved(carrier: carrier) }
        return CarrierAttestation(install: install, carrier: carrier)
    }
}
