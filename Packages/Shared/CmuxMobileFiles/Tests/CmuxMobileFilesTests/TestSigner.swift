import CmuxMobileLink
import CryptoKit
import Foundation

/// A paired device key in software.
struct TestSigner: MobileDeviceSigner {
    let key: P256.Signing.PrivateKey
    let install: String
    var keyID: String { "k1" }

    func sign(_ message: Data) throws -> Data {
        try key.signature(for: message).rawRepresentation
    }
}
