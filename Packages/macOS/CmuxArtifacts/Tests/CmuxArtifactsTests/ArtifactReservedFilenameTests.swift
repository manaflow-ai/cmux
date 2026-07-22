import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact reserved filenames")
struct ArtifactReservedFilenameTests {
    @Test("A first import named like the session marker preserves both files")
    func firstImportNamedLikeSessionMarker() async throws {
        try await assertFirstImport(
            named: ArtifactPathResolver.sessionMarkerName,
            expectedArtifactName: "_session-2.json"
        )
    }

    @Test("A case-variant session marker name cannot alias the managed marker")
    func firstImportNamedLikeCaseVariantSessionMarker() async throws {
        try await assertFirstImport(
            named: "_SESSION.JSON",
            expectedArtifactName: "_SESSION-2.JSON"
        )
    }

    private func assertFirstImport(
        named sourceName: String,
        expectedArtifactName: String
    ) async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write(
            "user artifact",
            named: sourceName,
            under: root.appendingPathComponent("outside")
        )

        let outcome = try await LocalArtifactRepository().importFile(
            sourceURL: source,
            context: ArtifactCaptureContext(
                projectRoot: root,
                workspaceID: "workspace:reserved",
                sessionID: "session:reserved"
            ),
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let record = try #require(outcome.record)
        #expect(record.relativePath.hasSuffix("/\(expectedArtifactName)"))
        let artifactURL = root.appendingPathComponent(".cmux/artifacts/\(record.relativePath)")
        #expect(try String(contentsOf: artifactURL, encoding: .utf8) == "user artifact")
        let markerURL = artifactURL.deletingLastPathComponent()
            .appendingPathComponent(ArtifactPathResolver.sessionMarkerName)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(markerURL != artifactURL)
    }
}
