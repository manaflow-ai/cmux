import CmuxMobileFiles
import CmuxMobileHost
import CmuxMobileWire
import CryptoKit
import Foundation

/// A paired device key in software.
struct TestSigner: MobileHelloSigner {
    let key: P256.Signing.PrivateKey
    let install: String

    var client: HelloClient { HelloClient(install: install, platform: "ios", appVersion: "1.0") }

    func proof(hostID: String, sessionID: UUID) async throws -> DeviceProof {
        try DeviceProof(install: install, keyID: "k1", issuedAt: Int64(Date().timeIntervalSince1970 * 1000),
                        hostID: hostID, sessionID: sessionID) { try key.signature(for: $0).rawRepresentation }
    }
}
