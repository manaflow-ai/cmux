public import Foundation

/// The peer a carrier authenticated below the session (B2: the identity key
/// bound to the DTLS fingerprint; B4: the Noise static key). Hosts feed it
/// to their authorizer (B5 `CarrierAttestation`); a session keeps the
/// identity of its first transport and `LinkHost` refuses to resume it on a
/// transport that proved another key of the same kind.
public struct LinkPeerIdentity: Sendable, Hashable {
    /// How `publicKey` is encoded.
    public enum KeyKind: String, Sendable, Hashable, Codable {
        /// P-256, X9.63 uncompressed (65 bytes).
        case p256
        /// X25519, raw (32 bytes).
        case x25519
    }

    public var carrier: CarrierKind
    public var keyKind: KeyKind
    public var publicKey: Data
    /// The install the control plane authenticated for this peer (B2's
    /// relay-rewritten `from`), when the carrier has one.
    public var install: String?

    public init(carrier: CarrierKind, keyKind: KeyKind, publicKey: Data, install: String? = nil) {
        self.carrier = carrier
        self.keyKind = keyKind
        self.publicKey = publicKey
        self.install = install
    }

    /// Whether both name the same key (the carrier and install may differ
    /// across carriers for one device).
    public func sameKey(as other: LinkPeerIdentity) -> Bool {
        keyKind == other.keyKind && publicKey == other.publicKey
    }
}
