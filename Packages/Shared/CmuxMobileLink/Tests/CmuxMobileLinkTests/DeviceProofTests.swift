import CmuxMobileLink
import CryptoKit
import Foundation
import Testing

@Suite("device proof")
struct DeviceProofTests {
    @Test func aProofVerifiesOnlyForItsHostAndLinkSession() throws {
        let key = P256.Signing.PrivateKey()
        let session = UUID()
        let proof = try DeviceProof(install: "in_1", keyID: "k1", issuedAt: 1_700_000_000_000, hostID: "h_1",
                                    sessionID: session) { try key.signature(for: $0).rawRepresentation }
        let decoded = try #require(DeviceProof(json: proof.jsonValue))
        #expect(decoded == proof)
        let publicKey = key.publicKey.x963Representation
        #expect(decoded.verifies(publicKey: publicKey, hostID: "h_1", sessionID: session))
        #expect(!decoded.verifies(publicKey: publicKey, hostID: "h_2", sessionID: session))
        #expect(!decoded.verifies(publicKey: publicKey, hostID: "h_1", sessionID: UUID()))
        #expect(!decoded.verifies(publicKey: P256.Signing.PrivateKey().publicKey.x963Representation, hostID: "h_1",
                                  sessionID: session))
    }
}
