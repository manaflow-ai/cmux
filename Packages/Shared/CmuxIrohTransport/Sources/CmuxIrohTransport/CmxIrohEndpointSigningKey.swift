import Foundation
#if canImport(IrohLib)
import IrohLib
#elseif canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The Ed25519 key behind an Iroh EndpointID: derives the public key and signs.
///
/// Apple builds use IrohLib's own key, so the derivation is the one the endpoint
/// uses. A build without IrohLib (the Linux package lane) uses Curve25519
/// signing, which derives the same RFC 8032 public key from the 32-byte seed and
/// produces signatures that verify against it.
struct CmxIrohEndpointSigningKey: Sendable {
    #if canImport(IrohLib)
    private let key: SecretKey
    #else
    // swift-crypto's key type is not Sendable; keep the seed and the derived
    // public key, and rebuild the private key to sign.
    private let seed: Data
    private let publicKey: Data
    #endif

    init(secretBytes: Data) throws {
        #if canImport(IrohLib)
        key = try SecretKey.fromBytes(bytes: secretBytes)
        #else
        publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secretBytes)
            .publicKey.rawRepresentation
        seed = secretBytes
        #endif
    }

    /// The 32-byte public key, the EndpointID's raw form.
    var publicKeyBytes: Data {
        #if canImport(IrohLib)
        key.public().toBytes()
        #else
        publicKey
        #endif
    }

    /// The 64-byte Ed25519 signature of `message`.
    func sign(_ message: Data) throws -> Data {
        #if canImport(IrohLib)
        key.sign(message: message).toBytes()
        #else
        try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: message)
        #endif
    }
}
