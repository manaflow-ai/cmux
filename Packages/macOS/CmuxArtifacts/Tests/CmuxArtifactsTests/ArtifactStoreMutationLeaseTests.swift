import Darwin
import Foundation
import Testing
@testable import CmuxArtifacts

@Suite("Artifact store mutation lease")
struct ArtifactStoreMutationLeaseTests {
    @Test("A second repository cannot mutate a leased store")
    func rejectsConcurrentProcessMutation() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let source = try ArtifactTestSupport.write(
            "artifact",
            named: "plan.md",
            under: root.appendingPathComponent("outside")
        )
        let paths = ArtifactStorePaths(projectRoot: root)
        try FileManager.default.createDirectory(
            at: paths.artifactsRoot,
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            paths.artifactsRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { _ = close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

        let repository = LocalArtifactRepository()
        let context = ArtifactCaptureContext(projectRoot: root)
        let blocked = await repository.importFiles(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .manual)],
            context: context,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(blocked.first == .rejected(.storeBusy(paths.artifactsRoot.path)))
        #expect(flock(descriptor, LOCK_UN) == 0)

        let retried = await repository.importFiles(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .manual)],
            context: context,
            configuration: .defaultValue,
            capturedAt: Date(timeIntervalSince1970: 2)
        )
        guard case .imported = retried.first else {
            Issue.record("Expected the import to succeed after the lease was released")
            return
        }
    }
}
