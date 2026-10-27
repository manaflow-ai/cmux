#if !canImport(IrohLib)
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The Ed25519 key behind an Iroh EndpointID where iroh-ffi does not exist
/// (Linux). Iroh's `SecretKey` is the RFC 8032 seed, so the same seed gives
/// the same public key here, and every signature verifies with the same key.
struct CmxIrohEndpointSigningKey: Sendable {
    /// The validated 32-byte seed. swift-crypto's key type is not `Sendable`,
    /// so the key is rebuilt from the seed for each use.
    private let seed: Data

    /// The 32-byte public key, which is the EndpointID.
    let publicKeyBytes: Data

    /// - Throws: Crypto's error when `secretKeyBytes` is not a 32-byte seed.
    init(secretKeyBytes: Data) throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secretKeyBytes)
        seed = secretKeyBytes
        publicKeyBytes = key.publicKey.rawRepresentation
    }

    /// The 64-byte Ed25519 signature of `message`.
    func signature(for message: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)
    }
}
#endif
