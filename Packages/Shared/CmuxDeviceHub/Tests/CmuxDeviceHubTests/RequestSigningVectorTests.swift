@testable import CmuxDeviceHub
import Foundation
import Testing

/// This app's signer against `schemas/device-hub/request-signing-vectors.json`, the file the hub
/// (`workers/device-hub`) and the Linux host (`cmux-rd-host`) test too, so a signer and the hub's
/// verifier cannot drift apart.
@Suite struct RequestSigningVectorTests {
    struct Vectors: Decodable {
        struct Canonical: Decodable {
            let name: String
            let method: String
            let pathAndQuery: String
            let ts: Int
            let body: String?
            let canonical: String
        }

        struct Signature: Decodable {
            let name: String
            let message: String
            let signature: String
            let verifies: Bool
        }

        struct Signatures: Decodable {
            let publicKey: String
            let cases: [Signature]
        }

        let canonical: [Canonical]
        let signatures: Signatures
    }

    static let path = "schemas/device-hub/request-signing-vectors.json"

    static func vectors() throws -> Vectors {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no \(path) above \(#filePath)")
            root = parent
        }
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: root.appendingPathComponent(path)))
    }

    @Test func canonicalStringsMatchTheVectors() throws {
        for c in try Self.vectors().canonical {
            let got = DeviceRequestSigner.canonical(method: c.method, pathAndQuery: c.pathAndQuery, timestamp: c.ts, body: c.body.map { Data($0.utf8) })
            #expect(got == c.canonical, "\(c.name)")
        }
    }

    @Test func signaturesVerifyAsTheVectorsSay() throws {
        let vectors = try Self.vectors()
        for c in vectors.signatures.cases {
            let verdict = DeviceIdentity.verify(signature: c.signature, of: Data(c.message.utf8), signingKey: vectors.signatures.publicKey)
            #expect(verdict == c.verifies, "\(c.name)")
        }
    }
}
