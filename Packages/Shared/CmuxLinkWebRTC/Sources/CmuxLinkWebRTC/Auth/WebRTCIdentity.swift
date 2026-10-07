public import Foundation

/// This install's signing identity (B6 provisions it; the Secure Enclave on
/// device). Signs the fingerprint binding of every description it sends.
public protocol WebRTCIdentity: Sendable {
    var publicKey: WebRTCPublicKey { get }
    /// ECDSA P-256 SHA-256, raw `r || s`.
    func sign(_ message: Data) throws -> Data
}
