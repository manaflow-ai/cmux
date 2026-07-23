import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact capture candidate folding")
struct ArtifactCaptureCandidateFoldingTests {
    @Test("A later authorizing detection upgrades an earlier reference")
    func preservesAuthorizingProvenance() async throws {
        let project = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(project) }
        let external = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(external) }
        let source = try ArtifactTestSupport.write("plan", named: "plan.md", under: external)
        let store = ConfiguredArtifactStore(
            configuration: ArtifactCaptureConfiguration.defaultValue
        )

        let outcomes = await ArtifactCaptureService(store: store).capture(
            candidates: [
                ArtifactCandidate(sourceURL: source, provenance: .referenced),
                ArtifactCandidate(sourceURL: source, provenance: .created),
            ],
            context: ArtifactCaptureContext(projectRoot: project)
        )

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.record?.provenance == .created)
        #expect(await store.importCount == 1)
    }
}
