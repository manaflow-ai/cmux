import CmuxNextUpdater
import Foundation
import Testing

/// The signed flags document's shared signature vectors
/// (`schemas/features/flags-vectors.json`): the app's `ContentSignature`
/// accepts exactly the cases the daemon's reader (cmux-tui
/// `feature_flags.rs`) accepts, after trimming the `.sig` text as
/// `ReleaseNotesStore` does. A tampered byte or a foreign key fails both.
@Suite struct FlagsDocumentVectorTests {
    struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let data: String
            let signature: String
            let valid: Bool
        }

        let publicKey: String
        let signature: [Case]

        enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
            case signature
        }
    }

    static func vectors() throws -> Vectors {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appending(path: "schemas/features/flags-vectors.json"))
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    @Test func theSharedSignatureVectorsVerifyAsInTheDaemon() throws {
        let vectors = try Self.vectors()
        #expect(vectors.signature.contains { $0.valid })
        #expect(vectors.signature.contains { !$0.valid })
        for vector in vectors.signature {
            let signature = vector.signature.trimmingCharacters(in: .whitespacesAndNewlines)
            let verified = ContentSignature.verify(
                Data(vector.data.utf8), signature: signature, publicKey: vectors.publicKey)
            #expect(verified == vector.valid, "\(vector.name)")
        }
    }

    @Test func theTestKeyIsNotTheContentSigningKey() throws {
        #expect(try Self.vectors().publicKey != ContentSignature.publicKey)
    }
}
