public import Foundation

/// The signer's identity key and its signature over the description's
/// fingerprint binding (b2-webrtc.md section 8). Wire: `auth {key, sig}`,
/// both base64.
public struct SignalAuth: Sendable, Hashable {
    /// X9.63 P-256 public key (65 bytes).
    public var key: Data
    /// ECDSA P-256 SHA-256 signature, raw `r || s` (64 bytes).
    public var signature: Data

    public init(key: Data, signature: Data) {
        self.key = key
        self.signature = signature
    }
}
