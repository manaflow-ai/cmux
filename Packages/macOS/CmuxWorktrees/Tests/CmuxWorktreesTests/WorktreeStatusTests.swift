@testable import CmuxWorktrees
import Foundation
import Testing

@Suite
struct WorktreeStatusTests {
    @Test
    func computesAheadAndBehindAgainstUpstream() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let upstreamBranch = "status-upstream"
        let remote = fixture.path("remote.git")
        _ = try await fixture.git(["init", "--bare", remote.path])
        _ = try await fixture.git(["remote", "add", "origin", remote.path])
        _ = try await fixture.git(["push", "origin", "HEAD:refs/heads/\(upstreamBranch)"])
        _ = try await fixture.git([
            "fetch", "origin", "\(upstreamBranch):refs/remotes/origin/\(upstreamBranch)",
        ])

        let path = fixture.path("worktrees/diverged")
        let worktree = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "diverged",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: path.path),
            on: fixture.host
        )
        _ = try await fixture.git([
            "branch", "--set-upstream-to=origin/\(upstreamBranch)", "diverged",
        ])
        try fixture.write("local\n", to: "local.txt", in: path)
        try await fixture.commit("local commit", in: path)

        let peer = fixture.path("peer")
        _ = try await fixture.git(["clone", "--branch", upstreamBranch, remote.path, peer.path])
        _ = try await fixture.git(["config", "user.name", "cmux tests"], in: peer)
        _ = try await fixture.git(["config", "user.email", "cmux-tests@example.com"], in: peer)
        try fixture.write("remote\n", to: "remote.txt", in: peer)
        try await fixture.commit("remote commit", in: peer)
        _ = try await fixture.git(["push", "origin", "HEAD:refs/heads/\(upstreamBranch)"], in: peer)
        _ = try await fixture.git(["fetch", "origin"])

        let status = try await WorktreeService().status(
            worktree: worktree.identity,
            on: fixture.host
        )
        #expect(status.branch == "diverged")
        #expect(status.upstream == "origin/\(upstreamBranch)")
        #expect(!status.isUpstreamGone)
        #expect(status.aheadCount == 1)
        #expect(status.behindCount == 1)
        #expect(status.dirtyFileCount == 0)
        #expect(status.operation == nil)
    }

    @Test
    func reportsGoneUpstreamWithoutFailing() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let upstreamBranch = "status-gone"
        let remote = fixture.path("remote.git")
        _ = try await fixture.git(["init", "--bare", remote.path])
        _ = try await fixture.git(["remote", "add", "origin", remote.path])
        _ = try await fixture.git(["push", "origin", "HEAD:refs/heads/\(upstreamBranch)"])
        _ = try await fixture.git([
            "fetch", "origin", "\(upstreamBranch):refs/remotes/origin/\(upstreamBranch)",
        ])

        let path = fixture.path("worktrees/gone-upstream")
        let worktree = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "gone-upstream",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: path.path),
            on: fixture.host
        )
        _ = try await fixture.git([
            "branch", "--set-upstream-to=origin/\(upstreamBranch)", "gone-upstream",
        ])
        // Delete the remote branch and its tracking ref: the upstream stays
        // configured, but its commit is no longer resolvable.
        _ = try await fixture.git(["push", "origin", "--delete", upstreamBranch])
        _ = try await fixture.git(["update-ref", "-d", "refs/remotes/origin/\(upstreamBranch)"])

        let status = try await WorktreeService().status(
            worktree: worktree.identity,
            on: fixture.host
        )
        #expect(status.branch == "gone-upstream")
        #expect(status.upstream == "origin/\(upstreamBranch)")
        #expect(status.isUpstreamGone)
        #expect(status.aheadCount == 0)
        #expect(status.behindCount == 0)
    }

    @Test
    func refusesStatusForUnlistedWorktreeIdentity() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let stale = WorktreeIdentity(
            host: fixture.host.id,
            repoPath: fixture.repository.path,
            worktreePath: fixture.path("worktrees/never-created").path
        )

        do {
            _ = try await WorktreeService().status(worktree: stale, on: fixture.host)
            Issue.record("Expected status to fail closed for an unlisted identity")
        } catch let error as WorktreeServiceError {
            #expect(error == .worktreeNotFound(stale.worktreePath))
        } catch {
            Issue.record("Expected WorktreeServiceError, got \(error)")
        }
    }

    @Test
    func detectsMergeAndRebaseAdministrativeState() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        let path = fixture.path("worktrees/operation")
        let worktree = try await WorktreeService().create(
            repoRoot: fixture.repository.path,
            name: "operation",
            baseRef: "HEAD",
            options: WorktreeCreateOptions(worktreePath: path.path),
            on: fixture.host
        )

        let dotGit = URL(fileURLWithPath: worktree.identity.worktreePath).appendingPathComponent(".git")
        let contents = try String(contentsOf: dotGit, encoding: .utf8)
        let gitDirectory = URL(fileURLWithPath: contents.replacingOccurrences(of: "gitdir:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines))
        let head = try #require(worktree.headOID)
        try head.write(
            to: gitDirectory.appendingPathComponent("MERGE_HEAD"),
            atomically: true,
            encoding: .utf8
        )
        let merging = try await WorktreeService().status(worktree: worktree.identity, on: fixture.host)
        #expect(merging.operation == .merge)

        try FileManager.default.removeItem(at: gitDirectory.appendingPathComponent("MERGE_HEAD"))
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("rebase-merge"),
            withIntermediateDirectories: true
        )
        let rebasing = try await WorktreeService().status(worktree: worktree.identity, on: fixture.host)
        #expect(rebasing.operation == .rebase)
    }
}
