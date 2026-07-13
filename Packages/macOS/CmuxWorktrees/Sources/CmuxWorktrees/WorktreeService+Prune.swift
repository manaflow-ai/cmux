import Foundation

extension WorktreeService {
    /// Explicitly prunes stale worktree administrative records.
    ///
    /// Normal list/create/status flows never prune. Removal invokes this only
    /// after Git reports a stale-administration error.
    ///
    /// - Parameters:
    ///   - repoRoot: A host-local directory inside the repository.
    ///   - host: The execution host.
    /// - Returns: Git's verbose prune output.
    /// - Throws: ``WorktreeServiceError`` when the host or Git command fails.
    public func prune(
        repoRoot: String,
        on host: any WorktreeExecutionHost
    ) async throws -> WorktreePruneResult {
        try await ensureAvailable(host)
        let result = try await runGit(
            on: host,
            directory: repoRoot,
            arguments: ["worktree", "prune", "--verbose"]
        )
        let output = [result.stdout, result.stderr]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return WorktreePruneResult(output: output)
    }
}
