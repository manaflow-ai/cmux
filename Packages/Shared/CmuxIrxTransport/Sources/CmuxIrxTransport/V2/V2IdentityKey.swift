public import Foundation
import CryptoKit

/// A fresh Ed25519 key used both for this v2 IROH endpoint and backend proofs.
public struct V2IdentityKey: Sendable {
    private let key: Curve25519.Signing.PrivateKey

    /// The public key in the backend's lower-case EndpointID representation.
    public var endpointID: String { key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined() }
    /// The 32-byte seed passed to IROH; never include it in telemetry or requests.
    public var secretKey: Data { key.rawRepresentation }

    /// Generates a completely new v2 key without importing older identity stores.
    public init() { key = Curve25519.Signing.PrivateKey() }

    /// Restores a seed read from this exact v2 identity's private store.
    /// - Parameter secretKey: This scope's previously generated 32-byte seed.
    /// - Throws: A cryptographic error for invalid seed bytes.
    public init(secretKey: Data) throws { key = try Curve25519.Signing.PrivateKey(rawRepresentation: secretKey) }

    /// Signs the canonical proof bytes used by the Worker.
    /// - Parameter data: Bytes produced by ``V2WireSigningCodec``.
    /// - Returns: A raw 64-byte Ed25519 signature.
    /// - Throws: A cryptographic error if signing fails.
    public func sign(_ data: Data) throws -> Data { try key.signature(for: data) }
}
