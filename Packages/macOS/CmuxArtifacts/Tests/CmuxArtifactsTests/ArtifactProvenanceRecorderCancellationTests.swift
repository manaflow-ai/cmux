import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact provenance cancellation")
struct ArtifactProvenanceRecorderCancellationTests {
    @Test("Canceled provenance reads propagate cancellation")
    func canceledReadPropagatesCancellation() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let paths = ArtifactStorePaths(projectRoot: root)
        try FileManager.default.createDirectory(at: paths.provenanceRoot, withIntermediateDirectories: true)
        let recorder = ArtifactProvenanceRecorder(
            fileManager: .default,
            encoder: JSONEncoder(),
            decoder: JSONDecoder()
        )
        let document = ArtifactMetadataDocument(
            version: 1,
            digest: "digest",
            lastKnownRelativePath: "plan.md",
            size: 4,
            events: []
        )
        try JSONEncoder().encode(document).write(
            to: recorder.metadataURL(paths: paths, digest: "digest")
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try recorder.document(paths: paths, digest: "digest")
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }
}
