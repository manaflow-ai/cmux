import Darwin
import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact Git exclude concurrency")
struct ArtifactGitExcludeConcurrencyTests {
    @Test("A held legacy lock cannot block Git exclude preparation")
    func heldLegacyLockDoesNotBlockPreparation() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let info = root.appendingPathComponent(".git/info", isDirectory: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let lockURL = info.appendingPathComponent("cmux-artifacts.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

        _ = try await LocalArtifactRepository().snapshot(projectRoot: root)

        let exclude = try String(
            contentsOf: info.appendingPathComponent("exclude"),
            encoding: .utf8
        )
        #expect(exclude.contains(".cmux/**"))
    }
}
