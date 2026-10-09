public import Foundation
import CryptoKit

/// A software P-256 identity (tests, simulators, Macs without a Secure
/// Enclave key yet).
public struct SoftwareWebRTCIdentity: WebRTCIdentity {
    private let privateKey: P256.Signing.PrivateKey
    public let publicKey: WebRTCPublicKey

    public init() {
        self.init(key: P256.Signing.PrivateKey())
    }

    /// Restores a stored key (`rawRepresentation`, 32 bytes).
    public init(privateKeyRepresentation: Data) throws {
        self.init(key: try P256.Signing.PrivateKey(rawRepresentation: privateKeyRepresentation))
    }

    private init(key: P256.Signing.PrivateKey) {
        privateKey = key
        self.publicKey = WebRTCPublicKey(cryptoKitKey: key.publicKey)
    }

    public var privateKeyRepresentation: Data { privateKey.rawRepresentation }

    public func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message).rawRepresentation
    }
}
