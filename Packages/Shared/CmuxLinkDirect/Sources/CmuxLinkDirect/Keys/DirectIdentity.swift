import CryptoKit
public import Foundation

/// The static X25519 key of a host or device. The private key stays on the
/// device (Keychain `ThisDeviceOnly`); only `publicKey` is shared at pairing.
public struct DirectIdentity: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    /// A new random key.
    public init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    /// Restores a key from its 32 raw bytes (as stored in the Keychain).
    public init(privateKeyRepresentation: Data) throws {
        privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyRepresentation)
    }

    /// The raw private key, for the caller's Keychain item. Never log it.
    public var privateKeyRepresentation: Data { privateKey.rawRepresentation }

    public var publicKey: DirectPublicKey {
        // A CryptoKit X25519 public key is always 32 bytes.
        DirectPublicKey(rawRepresentation: privateKey.publicKey.rawRepresentation)!
    }
}
