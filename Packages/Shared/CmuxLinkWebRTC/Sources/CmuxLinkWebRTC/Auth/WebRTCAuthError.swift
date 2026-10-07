/// Why a description's identity binding was refused (b2-webrtc.md section 8).
public enum WebRTCAuthError: Error, Sendable, Hashable {
    /// The description carried no `auth`.
    case missingAuth
    /// The key is not a valid P-256 point.
    case invalidKey
    /// The SDP has no `a=fingerprint`, a non-SHA-256 one, or several that differ.
    case badFingerprint
    /// The signature does not verify for the statement.
    case badSignature
    /// The key is not the pinned host key.
    case wrongHostKey
    /// The host's trust store refused the device key.
    case unauthorizedDevice
}
