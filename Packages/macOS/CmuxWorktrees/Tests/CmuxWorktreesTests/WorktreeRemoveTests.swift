@testable import CmuxWorktrees
import Foundation
import Testing

@Suite
struct WorktreeRemoveTests {
    @Test
    func refusesDirtyWorktreeWithoutForce() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let path = fixture.path("worktrees/dirty")
        let worktree = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "dirty",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: path.path),
            on: fixture.host
        )
        try fixture.write("untracked\n", to: "untracked.txt", in: path)

        do {
            _ = try await WorktreeService().remove(worktree: worktree.identity, on: fixture.host)
            Issue.record("Expected dirty removal refusal")
        } catch let error as WorktreeServiceError {
            #expect(error == .dirtyWorktree(path: worktree.identity.worktreePath, fileCount: 1))
        }
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test
    func preservesUnmergedBranchWhenDashDRefuses() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let path = fixture.path("worktrees/unmerged")
        let worktree = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "unmerged",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: path.path),
            on: fixture.host
        )
        try fixture.write("feature\n", to: "feature.txt", in: path)
        try await fixture.commit("feature", in: path)

        let result = try await WorktreeService().remove(
            worktree: worktree.identity,
            on: fixture.host
        )
        guard case let .preserved(branch, reason) = result.branchCleanup else {
            Issue.record("Expected branch preservation")
            return
        }
        #expect(branch == "unmerged")
        guard case .deleteIfMergedRefused = reason else {
            Issue.record("Expected git branch -d refusal")
            return
        }
        let branchStillExists = await fixture.gitRaw(["show-ref", "--verify", "refs/heads/unmerged"])
        #expect(branchStillExists.exitStatus == 0)
    }

    @Test
    func refusesMainWorktree() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let main = try #require(try await WorktreeService().list(
            repoRoot: fixture.repository.path,
            on: fixture.host
        ).first)

        do {
            _ = try await WorktreeService().remove(worktree: main.identity, on: fixture.host)
            Issue.record("Expected main-worktree refusal")
        } catch let error as WorktreeServiceError {
            #expect(error == .mainWorktreeRemovalRefused(main.identity.worktreePath))
        }
    }

    @Test
    func casMismatchPreservesMovedBranch() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let path = fixture.path("worktrees/cas")
        let worktree = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "cas",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: path.path),
            on: fixture.host
        )
        let staleOID = try #require(worktree.headOID)
        try fixture.write("moved\n", to: "moved.txt", in: path)
        try await fixture.commit("move branch", in: path)

        let result = try await WorktreeService().remove(
            worktree: worktree.identity,
            mode: WorktreeRemovalMode(branchCleanup: .forceDelete(expectedOID: staleOID)),
            on: fixture.host
        )
        guard case let .preserved(branch, reason) = result.branchCleanup else {
            Issue.record("Expected CAS mismatch to preserve the branch")
            return
        }
        #expect(branch == "cas")
        guard case .compareAndSwapRefused = reason else {
            Issue.record("Expected compare-and-swap refusal")
            return
        }
        let branchStillExists = await fixture.gitRaw(["show-ref", "--verify", "refs/heads/cas"])
        #expect(branchStillExists.exitStatus == 0)
    }

    @Test
    func casDeletionRemovesBranchConfiguration() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let path = fixture.path("worktrees/cas-config")
        let worktree = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "cas-config",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: path.path),
            on: fixture.host
        )
        let recordedBase = await fixture.gitRaw(["config", "--get", "branch.cas-config.base"])
        #expect(recordedBase.exitStatus == 0)
        let headOID = try #require(worktree.headOID)

        let result = try await WorktreeService().remove(
            worktree: worktree.identity,
            mode: WorktreeRemovalMode(branchCleanup: .forceDelete(expectedOID: headOID)),
            on: fixture.host
        )

        #expect(result.branchCleanup == .deleted(branch: "cas-config"))
        let branchGone = await fixture.gitRaw(["show-ref", "--verify", "refs/heads/cas-config"])
        #expect(branchGone.exitStatus != 0)
        let configGone = await fixture.gitRaw(["config", "--get", "branch.cas-config.base"])
        #expect(configGone.exitStatus != 0)
    }

    @Test
    func refusesLockedWorktreeUntilExplicitlyUnlocked() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let path = fixture.path("worktrees/locked")
        let worktree = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "locked",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: path.path),
            on: fixture.host
        )
        _ = try await fixture.git(["worktree", "lock", "--reason", "test lock", path.path])

        do {
            _ = try await WorktreeService().remove(worktree: worktree.identity, on: fixture.host)
            Issue.record("Expected locked-worktree refusal")
        } catch let error as WorktreeServiceError {
            #expect(error == .lockedWorktree(
                path: worktree.identity.worktreePath,
                reason: "test lock"
            ))
        }
    }

    @Test
    func genericValidationFailureDoesNotPruneUnrelatedRecords() async throws {
        let host = ValidationFailureWorktreeExecutionHost()
        let identity = WorktreeIdentity(
            host: host.id,
            repoPath: "/repo",
            worktreePath: "/repo/worktrees/feature"
        )

        do {
            _ = try await WorktreeService().remove(worktree: identity, on: host)
            Issue.record("Expected Git to refuse removing a worktree containing submodules")
        } catch let error as WorktreeServiceError {
            guard case let .commandFailed(_, _, message) = error else {
                Issue.record("Expected Git's validation failure, got \(error)")
                return
            }
            #expect(message.contains("working trees containing submodules"))
        }

        let commands = await host.recordedArguments()
        #expect(!commands.contains(["worktree", "prune", "--verbose"]))
    }

    @Test
    func staleAdministrativeFailurePrunesOnceAndRetriesRemoval() async throws {
        let host = ValidationFailureWorktreeExecutionHost(
            removalError: "fatal: validation failed, cannot remove working tree: unable to read gitdir file"
        )
        let identity = WorktreeIdentity(
            host: host.id,
            repoPath: "/repo",
            worktreePath: "/repo/worktrees/feature"
        )

        do {
            _ = try await WorktreeService().remove(worktree: identity, on: host)
            Issue.record("Expected removal to remain failed after one lazy-prune retry")
        } catch let error as WorktreeServiceError {
            guard case .commandFailed = error else {
                Issue.record("Expected Git's stale-administration failure, got \(error)")
                return
            }
        }

        let commands = await host.recordedArguments()
        #expect(commands.filter { $0 == ["worktree", "prune", "--verbose"] }.count == 1)
        #expect(commands.filter { $0 == ["worktree", "remove", identity.worktreePath] }.count == 2)
    }
}
