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

    @Test
    func fallsBackForUnsupportedNULModeAndDecodesQuotedPath() async throws {
        let lineOutput = #"""
        worktree "/repo/Caf\303\251\tworktree"
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        """#
        let host = WorktreeListCompatibilityHost(
            nulExitStatus: 129,
            nulStderr: "error: unknown switch `z'\nusage: git worktree list [<options>]",
            lineOutput: lineOutput
        )

        let worktrees = try await WorktreeService().list(repoRoot: "/repo", on: host)

        #expect(worktrees.map(\.identity.worktreePath) == ["/repo/Café\tworktree"])
        #expect(await host.recordedArguments() == [
            ["worktree", "list", "--porcelain", "-z"],
            ["worktree", "list", "--porcelain"],
        ])
    }

    @Test
    func doesNotFallbackAfterArbitraryNULModeFailure() async {
        let host = WorktreeListCompatibilityHost(
            nulExitStatus: 128,
            nulStderr: "fatal: not a git repository",
            lineOutput: "worktree /wrong-repository\n\n"
        )

        do {
            _ = try await WorktreeService().list(repoRoot: "/repo", on: host)
            Issue.record("Expected the original Git failure to propagate")
        } catch let error as WorktreeServiceError {
            guard case let .commandFailed(_, exitStatus, message) = error else {
                Issue.record("Expected a command failure, got \(error)")
                return
            }
            #expect(exitStatus == 128)
            #expect(message == "fatal: not a git repository")
        } catch {
            Issue.record("Expected WorktreeServiceError, got \(error)")
        }

        #expect(await host.recordedArguments() == [
            ["worktree", "list", "--porcelain", "-z"],
        ])
    }
}
