import CmuxFoundation
@testable import CmuxWorktrees
import Foundation
import Testing

@Suite
struct WorktreeHostSafetyTests {
    @Test
    func scrubsInheritedRepositoryLocalGitEnvironment() async throws {
        let fixture = try await GitTestRepository.make()
        defer { fixture.cleanup() }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_ALLOW_PROTOCOL"] = "file"
        environment["GIT_DIR"] = "/nonexistent/git-dir"
        environment["GIT_WORK_TREE"] = "/nonexistent/work-tree"
        environment["GIT_INDEX_FILE"] = "/nonexistent/index"
        let poisonedHost = LocalWorktreeExecutionHost(
            homeDirectory: fixture.host.homeDirectory,
            commandRunner: CommandRunner(environment: environment, bundledBinPath: nil)
        )

        let worktrees = try await WorktreeService().list(
            repoRoot: fixture.repository.path,
            on: poisonedHost
        )

        #expect(worktrees.count == 1)
        #expect(worktrees.first?.isMainWorktree == true)
    }


    @Test
    func destructiveOperationsFailClosedWhenHostIsUnavailable() async throws {
        let host = UnavailableWorktreeExecutionHost()
        let service = WorktreeService()

        do {
            _ = try await service.create(
                repoRoot: "/repo",
                name: "feature",
                baseRef: "HEAD",
                on: host
            )
            Issue.record("Expected create to fail closed")
        } catch let error as WorktreeServiceError {
            #expect(error == .hostUnavailable(host.id))
        }

        let identity = WorktreeIdentity(
            host: host.id,
            repoPath: "/repo",
            worktreePath: "/worktree"
        )
        do {
            _ = try await service.remove(worktree: identity, on: host)
            Issue.record("Expected remove to fail closed")
        } catch let error as WorktreeServiceError {
            #expect(error == .hostUnavailable(host.id))
        }

        do {
            _ = try await service.prune(repoRoot: "/repo", on: host)
            Issue.record("Expected prune to fail closed")
        } catch let error as WorktreeServiceError {
            #expect(error == .hostUnavailable(host.id))
        }
    }
}
