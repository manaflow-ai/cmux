import Foundation
import Testing
@testable import CmuxGit

@Suite struct ReftableGitMetadataTests {
    /// Reproduces a linked reftable worktree whose HEAD contains `.invalid`.
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

    /// Uses plumbing when a generated config exceeds the bounded backend scan.
    @Test func oversizedReferenceConfigFallsBackToGitPlumbing() throws {
        let fixture = try GitRepositoryFixture()
        try fixture.writeBranch(".invalid")
        try fixture.writeConfig(
            "[core]\n" + String(repeating: "generated = value\n", count: 70_000)
        )
        let repository = try #require(
            GitMetadataService.resolveGitRepository(containing: fixture.root.path)
        )
        let commit = String(repeating: "a", count: 40)
        let reader = SystemGitReferenceReader(
            runner: FakeWorkspaceChangesGitRunner(results: [
                ["symbolic-ref", "--quiet", "HEAD"]: FakeWorkspaceChangesGitRunner.result(
                    "refs/heads/feature/large-config\n"
                ),
                [
                    "rev-parse",
                    "--verify",
                    "refs/heads/feature/large-config^{commit}",
                ]: FakeWorkspaceChangesGitRunner.result("\(commit)\n"),
            ])
        )

        let snapshot = reader.snapshot(repository: repository)

        #expect(snapshot.checkedOutBranch == GitCheckedOutBranch.branch("feature/large-config"))
        #expect(snapshot.currentCommit == commit)
    }

    /// Keeps ambient Git repository overrides from redirecting plumbing reads.
    @Test func plumbingIgnoresAmbientRepositorySelection() throws {
        let fixture = try WorkspaceChangesGitRepositoryFixture(initializeRepository: false)
        let intended = fixture.root.appendingPathComponent("intended", isDirectory: true)
        let unrelated = fixture.root.appendingPathComponent("unrelated", isDirectory: true)
        let intendedBranch = "feature/intended"

        try fixture.git([
            "init", "--ref-format=reftable", "--initial-branch=\(intendedBranch)", intended.path,
        ])
        try fixture.git([
            "-C", intended.path,
            "-c", "user.name=cmux-tests",
            "-c", "user.email=cmux-tests@example.invalid",
            "commit", "--allow-empty", "-m", "intended",
        ])
        try fixture.git([
            "init", "--ref-format=reftable", "--initial-branch=feature/unrelated", unrelated.path,
        ])
        try fixture.git([
            "-C", unrelated.path,
            "-c", "user.name=cmux-tests",
            "-c", "user.email=cmux-tests@example.invalid",
            "commit", "--allow-empty", "-m", "unrelated",
        ])

        let intendedRepository = try #require(
            GitMetadataService.resolveGitRepository(containing: intended.path)
        )
        let unrelatedRepository = try #require(
            GitMetadataService.resolveGitRepository(containing: unrelated.path)
        )
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_DIR"] = unrelatedRepository.gitDirectory
        environment["GIT_WORK_TREE"] = unrelated.path
        environment["GIT_COMMON_DIR"] = unrelatedRepository.commonDirectory
        let reader = SystemGitReferenceReader(
            runner: SystemWorkspaceChangesGitRunner(environment: environment)
        )

        let snapshot = reader.snapshot(repository: intendedRepository)

        #expect(snapshot.checkedOutBranch == .branch(intendedBranch))
    }
}
