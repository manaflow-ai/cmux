import CryptoKit
public import Foundation

/// The install's static WireGuard key. Made on the device and kept in the
/// Keychain (`AfterFirstUnlockThisDeviceOnly`, never synced); only
/// `publicKey` leaves the device (transport.md section 8).
public struct WireGuardPrivateKey: Sendable {
    let key: Curve25519.KeyAgreement.PrivateKey

    /// A new random key.
    public init() {
        key = Curve25519.KeyAgreement.PrivateKey()
    }

    /// Restores a key from its 32 raw bytes.
    public init(rawRepresentation: Data) throws {
        key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    /// The raw private key, for the caller's Keychain item. Never log it.
    public var rawRepresentation: Data { key.rawRepresentation }

    public var publicKey: WireGuardPublicKey {
        // A CryptoKit X25519 public key is always 32 bytes.
        WireGuardPublicKey(rawRepresentation: key.publicKey.rawRepresentation)!
    }

    /// X25519 with `peer`. CryptoKit rejects an all-zero (low order) result.
    func sharedSecret(with peer: [UInt8]) throws -> [UInt8] {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
        let secret = try key.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.withUnsafeBytes { [UInt8]($0) }
    }
}
