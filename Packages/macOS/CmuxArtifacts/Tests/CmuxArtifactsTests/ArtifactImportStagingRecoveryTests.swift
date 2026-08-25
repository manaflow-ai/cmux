import Darwin
import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact import staging recovery")
struct ArtifactImportStagingRecoveryTests {
    @Test("Reads preserve staging while preparation reclaims only unlocked batches")
    func reclaimsOrphanWhilePreservingActiveBatch() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let stagingRoot = ArtifactStorePaths(projectRoot: root).importStagingRoot
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let orphan = stagingRoot.appendingPathComponent("orphan.artifact-import", isDirectory: true)
        let active = stagingRoot.appendingPathComponent("active.artifact-import", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
        _ = FileManager.default.createFile(
            atPath: orphan.appendingPathComponent(".lease").path,
            contents: Data()
        )
        let activeLeasePath = active.appendingPathComponent(".lease").path
        _ = FileManager.default.createFile(atPath: activeLeasePath, contents: Data())
        let activeDescriptor = Darwin.open(activeLeasePath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard activeDescriptor >= 0 else {
            Issue.record("Could not open the active import lease")
            return
        }
        defer {
            _ = flock(activeDescriptor, LOCK_UN)
            _ = close(activeDescriptor)
        }
        #expect(flock(activeDescriptor, LOCK_EX | LOCK_NB) == 0)

        let repository = LocalArtifactRepository()
        _ = try await repository.snapshot(projectRoot: root)

        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: active.path))

        try await repository.prepareForMutation(
            paths: ArtifactStorePaths(projectRoot: root)
        )

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: active.path))
    }

    @Test("Staging recovery never follows a stale batch symlink")
    func rejectsSymlinkedStaleBatch() throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let outside = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(outside) }
        let stagingRoot = ArtifactStorePaths(projectRoot: root).importStagingRoot
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let sentinel = try ArtifactTestSupport.write("keep", named: "sentinel.txt", under: outside)
        let stale = stagingRoot.appendingPathComponent("stale.artifact-import", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: stale, withDestinationURL: outside)

        ArtifactImportStagingCleaner(
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 10_000) },
            malformedEntryGracePeriod: 0
        ).reclaimAbandonedBatches(root: stagingRoot)

        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }
}
