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
}
