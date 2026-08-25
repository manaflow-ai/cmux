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
            at: paths.filesystemRoot,
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            paths.filesystemRoot.path,
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
            maximumBatchBytes: nil,
            capturedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(blocked.first == .rejected(.storeBusy(paths.filesystemRoot.path)))
        #expect(flock(descriptor, LOCK_UN) == 0)

        let retried = await repository.importFiles(
            candidates: [ArtifactCandidate(sourceURL: source, provenance: .manual)],
            context: context,
            configuration: .defaultValue,
            maximumBatchBytes: nil,
            capturedAt: Date(timeIntervalSince1970: 2)
        )
        guard case .imported = retried.first else {
            Issue.record("Expected the import to succeed after the lease was released")
            return
        }
    }

    @Test("A swapped destination parent cannot redirect a staged move")
    func rejectsSwappedDestinationParent() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let outside = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(outside) }
        let paths = ArtifactStorePaths(projectRoot: root)
        try FileManager.default.createDirectory(
            at: paths.filesystemRoot.appendingPathComponent("session/artifacts"),
            withIntermediateDirectories: true
        )
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let source = try ArtifactTestSupport.write("staged", named: "plan.md", under: staging)
        let expectedSourceParentPath = staging.resolvingSymlinksInPath().standardizedFileURL.path
        let lease = try ArtifactStoreMutationLease(directory: paths.filesystemRoot)
        defer { lease.finish() }

        try FileManager.default.removeItem(
            at: paths.filesystemRoot.appendingPathComponent("session")
        )
        try FileManager.default.createSymbolicLink(
            at: paths.filesystemRoot.appendingPathComponent("session"),
            withDestinationURL: outside
        )

        #expect(throws: ArtifactStoreError.self) {
            try lease.moveFile(
                from: source,
                toRelativePath: "session/artifacts/plan.md",
                expectedSourceParentPath: expectedSourceParentPath
            )
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("artifacts/plan.md").path
        ))
    }
}
