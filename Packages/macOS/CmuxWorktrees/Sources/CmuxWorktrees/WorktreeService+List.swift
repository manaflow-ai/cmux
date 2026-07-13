import Foundation

extension WorktreeService {
    /// Resolves the repository root containing a host-local directory.
    /// - Parameters:
    ///   - directory: A repository directory or any descendant directory.
    ///   - host: The execution host.
    /// - Returns: Git's absolute top-level worktree path.
    /// - Throws: ``WorktreeServiceError`` when the host or Git command fails.
    public func repositoryRoot(
        containing directory: String,
        on host: any WorktreeExecutionHost
    ) async throws -> String {
        try await ensureAvailable(host)
        let result = try await runGit(
            on: host,
            directory: directory,
            arguments: ["rev-parse", "--show-toplevel"]
        )
        return normalizedPath(result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? directory)
    }

    /// Lists every worktree Git currently reports for a repository.
    /// - Parameters:
    ///   - repoRoot: A host-local directory inside the repository.
    ///   - host: The execution host.
    /// - Returns: Fresh porcelain snapshots in Git's order.
    /// - Throws: ``WorktreeServiceError`` when the host or Git command fails.
    public func list(
        repoRoot: String,
        on host: any WorktreeExecutionHost
    ) async throws -> [WorktreeInfo] {
        try await ensureAvailable(host)
        let result = try await runGit(
            on: host,
            directory: repoRoot,
            arguments: ["worktree", "list", "--porcelain"]
        )
        return parser.parse(
            result.stdout ?? "",
            host: host.id,
            fallbackRepoPath: normalizedPath(repoRoot)
        )
    }

    func listedWorktree(
        identity: WorktreeIdentity,
        on host: any WorktreeExecutionHost
    ) async throws -> WorktreeInfo {
        let worktrees = try await list(repoRoot: identity.repoPath, on: host)
        guard let match = worktrees.first(where: {
            samePath($0.identity.worktreePath, identity.worktreePath)
        }) else {
            throw WorktreeServiceError.worktreeNotFound(identity.worktreePath)
        }
        return match
    }
}
