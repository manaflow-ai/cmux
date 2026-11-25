public import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A fresh Ed25519 key used both for this v2 IROH endpoint and backend proofs.
public struct V2IdentityKey: Sendable {
    /// The 32-byte seed passed to IROH; never include it in telemetry or requests. Kept as bytes,
    /// not a key value: swift-crypto's key type is not `Sendable`.
    public let secretKey: Data

    /// The public key in the backend's lower-case EndpointID representation.
    public let endpointID: String

    /// Generates a completely new v2 key without importing older identity stores.
    public init() { self.init(key: Curve25519.Signing.PrivateKey()) }

    /// Restores a seed read from this exact v2 identity's private store.
    /// - Parameter secretKey: This scope's previously generated 32-byte seed.
    /// - Throws: A cryptographic error for invalid seed bytes.
    public init(secretKey: Data) throws { self.init(key: try Curve25519.Signing.PrivateKey(rawRepresentation: secretKey)) }

    private init(key: Curve25519.Signing.PrivateKey) {
        secretKey = key.rawRepresentation
        endpointID = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// Signs the canonical proof bytes used by the Worker.
    /// - Parameter data: Bytes produced by ``V2WireSigningCodec``.
    /// - Returns: A raw 64-byte Ed25519 signature.
    /// - Throws: A cryptographic error if signing fails.
    public func sign(_ data: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: secretKey).signature(for: data)
    }
}
