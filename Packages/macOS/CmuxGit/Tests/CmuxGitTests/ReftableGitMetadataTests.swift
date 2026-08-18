import Foundation
import Testing
@testable import CmuxGit

@Suite struct ReftableGitMetadataTests {
    @Test func metadataUsesGitResolvedWorktreeBranchAndWatchesReftableStorage() async throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: false)
        let repository = fixture.root.appendingPathComponent("repository", isDirectory: true)
        let worktree = fixture.root.appendingPathComponent("worktree", isDirectory: true)
        let initialBranch = "feature/reftable-sidebar"
        let nextBranch = "feature/reftable-sidebar-next"

        try fixture.git([
            "init", "--ref-format=reftable", "--initial-branch=main", repository.path,
        ])
        try fixture.git([
            "-C", repository.path,
            "-c", "user.name=cmux-tests",
            "-c", "user.email=cmux-tests@example.invalid",
            "commit", "--allow-empty", "-m", "baseline",
        ])
        try fixture.git([
            "-C", repository.path,
            "worktree", "add", "-b", initialBranch, worktree.path,
        ])

        let resolved = try #require(GitMetadataService.resolveGitRepository(containing: worktree.path))
        let head = try String(
            contentsOf: URL(fileURLWithPath: resolved.gitDirectory).appendingPathComponent("HEAD"),
            encoding: .utf8
        )
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "ref: refs/heads/.invalid")

        let service = GitMetadataService()
        let initialMetadata = await service.workspaceMetadata(for: worktree.path)
        #expect(initialMetadata.branch == initialBranch)
        #expect(await service.checkedOutBranch(forDirectory: worktree.path) == .branch(initialBranch))

        let descriptor = try #require(await service.watchDescriptor(for: worktree.path))
        let worktreeReftable = URL(fileURLWithPath: resolved.gitDirectory)
            .appendingPathComponent("reftable", isDirectory: true)
            .standardizedFileURL.path
        let commonReftable = URL(fileURLWithPath: resolved.commonDirectory)
            .appendingPathComponent("reftable", isDirectory: true)
            .standardizedFileURL.path
        #expect(descriptor.watchedPaths.contains(worktreeReftable))
        #expect(descriptor.watchedPaths.contains(commonReftable))
        #expect(descriptor.containsGitMetadataChange(
            paths: [URL(fileURLWithPath: worktreeReftable).appendingPathComponent("tables.list").path]
        ))

        try fixture.git([
            "-C", worktree.path,
            "switch", "-c", nextBranch,
        ])
        let nextMetadata = await service.workspaceMetadata(for: worktree.path)
        #expect(nextMetadata.branch == nextBranch)
        #expect(nextMetadata.headSignature != initialMetadata.headSignature)
    }
}
