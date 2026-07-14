@testable import CmuxWorktrees
import Foundation
import Testing

@Suite
struct WorktreeListTests {
    @Test
    func resolvesBareRepositoryRoot() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let bareRepository = fixture.path("bare.git")
        _ = try await fixture.git(["init", "--bare", bareRepository.path])

        let resolved = try await WorktreeService().repositoryRoot(
            containing: bareRepository.path,
            on: fixture.host
        )

        #expect(resolved == bareRepository.path)
    }
}
