import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact reserved filenames")
struct ArtifactReservedFilenameTests {
    @Test("A first import named like the session marker preserves both files")
    func firstImportNamedLikeSessionMarker() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write(
            "user artifact",
            named: ArtifactPathResolver.sessionMarkerName,
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
        #expect(record.relativePath.hasSuffix("/_session-2.json"))
        let artifactURL = root.appendingPathComponent(".cmux/artifacts/\(record.relativePath)")
        #expect(try String(contentsOf: artifactURL, encoding: .utf8) == "user artifact")
        let markerURL = artifactURL.deletingLastPathComponent()
            .appendingPathComponent(ArtifactPathResolver.sessionMarkerName)
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        #expect(markerURL != artifactURL)
    }
}
