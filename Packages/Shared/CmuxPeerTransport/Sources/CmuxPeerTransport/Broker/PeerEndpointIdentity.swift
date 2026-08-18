public import CMUXMobileCore
public import Foundation
import CryptoKit

/// Failures while validating or reconciling device-local endpoint identity.
public enum PeerIdentityError: Error, Equatable, Sendable {
    /// Endpoint secrets are exactly 32 bytes.
    case invalidSecretByteCount(Int)
    /// The account or app-instance identifier is empty or too large.
    case invalidScope
    /// Stored identity bytes do not match the versioned record contract.
    case corruptRecord
    /// The identity generation is zero, exhausted, or database-incompatible.
    case invalidGeneration
    /// Too many identity operations are waiting behind a stalled persistence call.
    case operationLimitExceeded
    /// Secure random generation failed with the platform status code.
    case randomGenerationFailed(Int32)
    /// Secure storage could not be read or written right now (for example the
    /// Keychain is unavailable before first unlock). The caller must treat
    /// this as transient; it never justifies minting a replacement identity.
    case storeUnavailable(status: Int32)
}

/// A validated 32-byte Ed25519 secret that determines an EndpointID.
public struct PeerSecretKey: Equatable, Sendable {
    /// The raw secret bytes supplied only to the endpoint factory.
    public let bytes: Data

    /// - Parameter bytes: Exactly 32 random bytes from device-local storage.
    public init(bytes: Data) throws {
        guard bytes.count == 32 else {
            throw PeerIdentityError.invalidSecretByteCount(bytes.count)
        }
        self.bytes = bytes
    }
}

/// Stable endpoint identity for one signed-in account and app instance.
///
/// The EndpointID is derived at construction with CryptoKit's Ed25519, which
/// is bit-identical to iroh's own key derivation (an iroh EndpointID is the
/// Ed25519 public key of the secret, hex-encoded), so identities persisted by
/// the previous transport derive the same EndpointID here.
public struct PeerEndpointIdentity: Equatable, Sendable {
    /// The device-local Ed25519 secret that determines the EndpointID.
    public let secretKey: PeerSecretKey

    /// Monotonic generation changed only when this identity rotates.
    public let generation: Int

    /// The peer identity this material's secret derives.
    public let endpointID: CmxIrohPeerIdentity

    /// - Parameters:
    ///   - secretKey: The 32-byte endpoint secret.
    ///   - generation: A positive PostgreSQL-compatible identity generation.
    public init(secretKey: PeerSecretKey, generation: Int) throws {
        guard (1 ... Int(Int32.max)).contains(generation) else {
            throw PeerIdentityError.invalidGeneration
        }
        self.secretKey = secretKey
        self.generation = generation
        let signingKey: Curve25519.Signing.PrivateKey
        do {
            signingKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: secretKey.bytes
            )
        } catch {
            throw PeerIdentityError.invalidSecretByteCount(secretKey.bytes.count)
        }
        endpointID = try CmxIrohPeerIdentity(
            endpointID: PeerBrokerWire.hex(signingKey.publicKey.rawRepresentation)
        )
    }
}
