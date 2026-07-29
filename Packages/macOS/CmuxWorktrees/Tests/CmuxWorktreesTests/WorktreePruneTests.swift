@testable import CmuxWorktrees
import Foundation
import Testing

@Suite
struct WorktreePruneTests {
    @Test
    func dryRunReportsStaleRecordsWithoutRemovingThem() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let service = WorktreeService()
        let path = fixture.path("worktrees/stale")
        let worktree = try await service.create(
            repoRoot: fixture.repository.path,
            name: "stale",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: path.path),
            on: fixture.host
        )
        try FileManager.default.removeItem(at: path)

        let planned = try await service.prune(
            repoRoot: fixture.repository.path,
            on: fixture.host,
            dryRun: true
        )
        #expect(!planned.output.isEmpty)

        let afterDryRun = try await service.list(
            repoRoot: fixture.repository.path,
            on: fixture.host
        )
        #expect(afterDryRun.contains {
            $0.identity.worktreePath == worktree.identity.worktreePath
        })

        let pruned = try await service.prune(
            repoRoot: fixture.repository.path,
            on: fixture.host
        )
        #expect(!pruned.output.isEmpty)

        let afterPrune = try await service.list(
            repoRoot: fixture.repository.path,
            on: fixture.host
        )
        #expect(!afterPrune.contains {
            $0.identity.worktreePath == worktree.identity.worktreePath
        })
    }
}
