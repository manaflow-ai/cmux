import CryptoKit
@testable import CmuxNextDevices
import Foundation
import Testing

/// CMUX-572: the proof the viewer's Touch ID key signs is, byte for byte, the one the host verifies
/// (`cmux-tui/crates/acpmux/src/viewer_grant.rs`): both read `viewer_grant_vectors.json`.
@Suite struct ViewerGrantProofTests {
    static func vectors() -> [[String: Any]] {
        let repo = (0..<6).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let file = repo.appendingPathComponent("cmux-tui/crates/acpmux/src/viewer_grant_vectors.json")
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    static func proof(_ fields: [String: Any]) -> ViewerGrantProof? {
        let text: (String) -> String = { fields[$0] as? String ?? "" }
        guard let scope = ViewerGrantScope(rawValue: text("scope")) else { return nil }
        return ViewerGrantProof(host: text("host"), viewer: text("viewer"), scope: scope, session: text("session"),
                                challenge: text("challenge"))
    }

    @Test func canonicalMatchesTheRustVectors() {
        let vectors = Self.vectors()
        #expect(vectors.count >= 2)
        for vector in vectors {
            let fields = vector["proof"] as? [String: Any] ?? [:]
            #expect(fields["v"] as? String == ViewerGrantProof.version)
            #expect(Self.proof(fields)?.canonical == vector["canonical"] as? String)
            #expect(Self.proof(fields)?.json["v"] == ViewerGrantProof.version)
        }
    }

    @Test func everyScopeIsInTheVectorsAndViewIsNotControl() {
        let scopes = Set(Self.vectors().compactMap { ($0["proof"] as? [String: Any]).flatMap(Self.proof)?.scope })
        #expect(scopes == Set(ViewerGrantScope.allCases))
    }

    /// A proof signed with a P-256 key verifies with that key's X9.63 public half (what the host
    /// registers), and stops verifying when any signed field changes.
    @Test func theSignatureCoversEverySignedField() throws {
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation.base64EncodedString()
        let proof = try ViewerGrantProof(host: "host", viewer: "viewer", scope: .view, session: "sess_1", challenge: "c")
            .signed { try key.signature(for: $0).rawRepresentation }
        #expect(DeviceIdentity.verify(signature: proof.signature, of: Data(proof.canonical.utf8), signingKey: publicKey))
        let changes: [(inout ViewerGrantProof) -> Void] = [
            { $0.host = "other" }, { $0.viewer = "other" }, { $0.scope = .control }, { $0.session = "sess_2" }, { $0.challenge = "d" },
        ]
        for change in changes {
            var changed = proof
            change(&changed)
            #expect(!DeviceIdentity.verify(signature: changed.signature, of: Data(changed.canonical.utf8), signingKey: publicKey))
        }
    }

    @Test func eachHostAndScopeHasItsOwnKey() {
        #expect(ViewerGrantKeys.account(host: "h", scope: .view) != ViewerGrantKeys.account(host: "h", scope: .control))
        #expect(ViewerGrantKeys.account(host: "h", scope: .view) != ViewerGrantKeys.account(host: "g", scope: .view))
    }
}
