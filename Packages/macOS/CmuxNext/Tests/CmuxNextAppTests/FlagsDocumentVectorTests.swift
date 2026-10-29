import CmuxNextUpdater
import Foundation
import Testing

/// The signed flags document's shared signature vectors
/// (`schemas/features/flags-vectors.json`): the app's `ContentSignature`
/// accepts exactly the cases the daemon's reader (cmux-tui
/// `feature_flags.rs`) accepts, after trimming the `.sig` text as
/// `ReleaseNotesStore` does. A tampered byte or a foreign key fails both.
/// The `resolve` and `serial` cases are decoded in the shape the daemon
/// replays (each layer gated on its own, one serial per document), so the
/// app's remote overrides model reads the same.
@Suite struct FlagsDocumentVectorTests {
    struct Vectors: Decodable {
        struct Case: Decodable {
            let name: String
            let data: String
            let signature: String
            let valid: Bool
        }

        struct Rejection: Decodable {
            let layer: String
            let reason: String
        }

        struct ResolveCase: Decodable {
            let name: String
            let cohort: String
            let build: Int?
            let now: Int
            let features: [String: Bool]
            let serial: Int?
            let rejected: [Rejection]
        }

        struct SerialCase: Decodable {
            let name: String
            let refused: Bool
        }

        let publicKey: String
        let signature: [Case]
        let resolve: [ResolveCase]
        let serial: [SerialCase]

        enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
            case signature
            case resolve
            case serial
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

    @Test func aRejectedCohortLayerKeepsTheDefaultsFeatures() throws {
        let vectors = try Self.vectors()
        let layers: Set<String> = ["default", "cohort"]
        let reasons: Set<String> = ["malformed", "expired", "buildUnknown", "buildBelowMin", "buildAboveMax"]
        for vector in vectors.resolve {
            for rejection in vector.rejected {
                #expect(layers.contains(rejection.layer), "\(vector.name)")
                #expect(reasons.contains(rejection.reason), "\(vector.name)")
            }
        }
        let belowMin = vectors.resolve.first { $0.cohort == "builds-4200-4299" && $0.build == 4199 }
        #expect(belowMin?.features == ["terminalHolder": false, "cefLayerHosting": false])
        #expect(belowMin?.rejected.map(\.layer) == ["cohort"])
    }

    @Test func aReplayThatDropsACohortIsRefused() throws {
        let serial = try Self.vectors().serial
        #expect(serial.contains { $0.refused })
        #expect(serial.contains { !$0.refused })
        #expect(serial.first { $0.name.contains("drops the cohort") }?.refused == true)
    }

    @Test func theTestKeyIsNotTheContentSigningKey() throws {
        #expect(try Self.vectors().publicKey != ContentSignature.publicKey)
    }
}
