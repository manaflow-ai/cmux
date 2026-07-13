@testable import CmuxWorktrees
import Testing

@Suite
struct WorktreeHostSafetyTests {
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
