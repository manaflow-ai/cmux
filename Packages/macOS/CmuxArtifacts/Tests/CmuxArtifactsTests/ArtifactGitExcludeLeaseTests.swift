import Darwin
import Foundation
import Testing

@testable import CmuxArtifacts

@Suite("Artifact Git exclude lease")
struct ArtifactGitExcludeLeaseTests {
    @Test("A held Git exclude lease fails closed within its bounded deadline")
    func heldLeaseFailsClosed() async throws {
        let root = try ArtifactTestSupport.temporaryDirectory()
        defer { ArtifactTestSupport.remove(root) }
        let lockURL = root.appendingPathComponent("cmux-artifacts.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let unlockTask = Task.detached {
            // This bounded delay keeps the regression from hanging on the old blocking lock.
            try await Task.sleep(for: .milliseconds(350))
            _ = flock(descriptor, LOCK_UN)
        }

        #expect(throws: ArtifactStoreError.gitPrivacyUnavailable(lockURL.path)) {
            _ = try ArtifactGitExcludeLease(url: lockURL)
        }
        try await unlockTask.value
    }
}
