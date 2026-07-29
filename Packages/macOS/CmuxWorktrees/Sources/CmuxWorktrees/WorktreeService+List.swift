import CmuxFoundation
import Foundation

extension WorktreeService {
    /// Resolves the repository root containing a host-local directory.
    /// - Parameters:
    ///   - directory: A repository directory or any descendant directory.
    ///   - host: The execution host.
    /// - Returns: Git's absolute top-level worktree path, or its absolute Git directory when bare.
    /// - Throws: ``WorktreeServiceError`` when the host or Git command fails.
    public func repositoryRoot(
        containing directory: String,
        on host: any WorktreeExecutionHost
    ) async throws -> String {
        try await ensureAvailable(host)
        let arguments = ["rev-parse", "--show-toplevel"]
        let topLevel = await host.run(
            directory: directory,
            executable: "git",
            arguments: arguments,
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.readTimeout
        )
        if topLevel.executionError == nil, !topLevel.timedOut, topLevel.exitStatus == 0 {
            return normalizedPath(
                topLevel.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? directory
            )
        }
        if topLevel.executionError != nil || topLevel.timedOut {
            _ = try successfulResult(
                topLevel,
                executable: "git",
                arguments: arguments,
                timeout: WorktreeService.readTimeout
            )
        }

        let bare = try await runGit(
            on: host,
            directory: directory,
            arguments: ["rev-parse", "--is-bare-repository"]
        )
        guard bare.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            _ = try successfulResult(
                topLevel,
                executable: "git",
                arguments: arguments,
                timeout: WorktreeService.readTimeout
            )
            return normalizedPath(directory)
        }
        let gitDirectory = try await runGit(
            on: host,
            directory: directory,
            arguments: ["rev-parse", "--absolute-git-dir"]
        )
        return normalizedPath(
            gitDirectory.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? directory
        )
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
        let nulArguments = ["worktree", "list", "--porcelain", "-z"]
        let nulResult = await host.run(
            directory: repoRoot,
            executable: "git",
            arguments: nulArguments,
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.readTimeout
        )
        let result: CommandResult
        if nulResult.executionError == nil, !nulResult.timedOut, nulResult.exitStatus == 0 {
            result = nulResult
        } else if nulResult.executionError == nil,
                  !nulResult.timedOut,
                  isUnsupportedNULTerminatedList(nulResult) {
            // Git added `worktree list -z` after porcelain mode; retain compatibility
            // with the older system Git shipped on supported macOS versions.
            result = try await runGit(
                on: host,
                directory: repoRoot,
                arguments: ["worktree", "list", "--porcelain"]
            )
        } else {
            result = try successfulResult(
                nulResult,
                executable: "git",
                arguments: nulArguments,
                timeout: WorktreeService.readTimeout
            )
        }
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

    func isUnsupportedNULTerminatedList(_ result: CommandResult) -> Bool {
        guard result.exitStatus == 129 else { return false }
        let message = commandMessage(result).lowercased()
        let diagnostics = [
            "unknown switch `z'",
            "unknown switch 'z'",
            "unknown option `z'",
            "unknown option 'z'",
            "unknown option '-z'",
            "unknown option: -z",
            "unrecognized option `z'",
            "unrecognized option 'z'",
            "unrecognized option '-z'",
        ]
        return diagnostics.contains(where: message.contains)
    }
}
