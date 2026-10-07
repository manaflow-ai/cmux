public import Foundation
import CryptoKit

/// A Secure Enclave P-256 identity: the private key never leaves the
/// enclave; `dataRepresentation` is an opaque, device-bound handle the
/// caller stores in the Keychain.
public struct SecureEnclaveWebRTCIdentity: WebRTCIdentity {
    private let privateKey: SecureEnclave.P256.Signing.PrivateKey
    public let publicKey: WebRTCPublicKey

    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    public init() throws {
        try self.init(key: SecureEnclave.P256.Signing.PrivateKey())
    }

    public init(dataRepresentation: Data) throws {
        try self.init(key: SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation))
    }

    private init(key: SecureEnclave.P256.Signing.PrivateKey) throws {
        privateKey = key
        guard let publicKey = WebRTCPublicKey(x963Representation: key.publicKey.x963Representation) else {
            throw WebRTCAuthError.invalidKey
        }
        self.publicKey = publicKey
    }

    public var dataRepresentation: Data { privateKey.dataRepresentation }

    public func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message).rawRepresentation
    }
}
