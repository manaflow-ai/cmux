import CmuxPairing
import CryptoKit
import Foundation

/// A software P-256 key standing in for the Secure Enclave install key.
struct SoftwareSigner: LinkKeySigning {
    let key: P256.Signing.PrivateKey

    init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) { self.key = key }

    var publicKey: InstallPublicKey { InstallPublicKey(key.publicKey) }

    func sign(_ message: Data) async throws -> Data { try key.signature(for: message).rawRepresentation }
}
