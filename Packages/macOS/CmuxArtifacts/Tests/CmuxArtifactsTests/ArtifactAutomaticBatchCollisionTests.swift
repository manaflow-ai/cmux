import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact automatic batch collisions")
struct ArtifactAutomaticBatchCollisionTests {
    @Test("Case-variant filenames in one batch receive distinct destinations")
    func caseVariantFilenamesReceiveDistinctDestinations() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        #expect(try ArtifactTestSupport.runGit(["init", "--quiet", root.path]) == 0)
        let first = try ArtifactTestSupport.write(
            "lowercase",
            named: "report.md",
            under: root.appendingPathComponent("sources/one")
        )
        let second = try ArtifactTestSupport.write(
            "uppercase",
            named: "REPORT.md",
            under: root.appendingPathComponent("sources/two")
        )

        let attempts = await LocalArtifactRepository().importFiles(
            candidates: [
                ArtifactCandidate(sourceURL: first, provenance: .created),
                ArtifactCandidate(sourceURL: second, provenance: .created),
            ],
            context: ArtifactCaptureContext(
                projectRoot: root,
                workspaceID: "workspace:batch",
                sessionID: "session:batch"
            ),
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let records = attempts.compactMap { attempt -> ArtifactRecord? in
            guard case .imported(let outcome) = attempt else { return nil }
            return outcome.record
        }

        #expect(records.count == 2)
        #expect(Set(records.map(\.relativePath)).count == 2)
        let storedContents = try records.map { record in
            try String(
                contentsOf: root.appendingPathComponent(".cmux/\(record.relativePath)"),
                encoding: .utf8
            )
        }
        #expect(Set(storedContents) == ["lowercase", "uppercase"])
    }
}
