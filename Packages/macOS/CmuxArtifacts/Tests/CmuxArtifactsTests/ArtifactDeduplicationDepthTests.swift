import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact deduplication scan depth")
struct ArtifactDeduplicationDepthTests {
    @Test("Moved-file recovery does not descend beyond the repository scan depth")
    func boundsOpenDirectoryEnumerators() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let paths = ArtifactStorePaths(projectRoot: root)
        _ = try ArtifactTestSupport.write(
            "same bytes",
            named: "one/two/existing.md",
            under: paths.artifactsRoot
        )
        let source = try ArtifactTestSupport.write(
            "same bytes",
            named: "outside/incoming.md",
            under: root
        )
        let repository = LocalArtifactRepository(maximumScanDepth: 1)

        let outcome = try await repository.importFile(
            sourceURL: source,
            context: ArtifactCaptureContext(projectRoot: root),
            provenance: .manual,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1)
        )

        guard case .copied = outcome else {
            Issue.record("Expected a bounded scan to copy instead of finding the deep duplicate")
            return
        }
    }
}
