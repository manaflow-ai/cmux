import CmuxFoundation
import Foundation

extension WorktreeService {
    /// Removes a linked worktree through a fail-closed safety state machine.
    ///
    /// Git is re-read after the dirty check so main/locked state is fresh at the
    /// destructive boundary. Normal cleanup uses `git branch -d`; compare-and-
    /// swap `git update-ref -d` is the only force-branch-delete path.
    ///
    /// - Parameters:
    ///   - worktree: The location-based worktree identity.
    ///   - mode: Dirty-file and branch-cleanup policy.
    ///   - host: The execution host matching the identity.
    /// - Returns: The completed worktree and branch cleanup outcome.
    /// - Throws: ``WorktreeServiceError`` when any safety condition fails.
    public func remove(
        worktree: WorktreeIdentity,
        mode: WorktreeRemovalMode = WorktreeRemovalMode(),
        on host: any WorktreeExecutionHost
    ) async throws -> WorktreeRemovalResult {
        try ensureIdentityHost(worktree, matches: host)
        try await ensureAvailable(host)

        let initial = try await listedWorktree(identity: worktree, on: host)
        guard !initial.isMainWorktree else {
            throw WorktreeServiceError.mainWorktreeRemovalRefused(worktree.worktreePath)
        }

        if !mode.forceWorktreeRemoval {
            let dirtyFileCount = try await dirtyFileCountForRemoval(worktree: worktree, on: host)
            guard dirtyFileCount == 0 else {
                throw WorktreeServiceError.dirtyWorktree(
                    path: worktree.worktreePath,
                    fileCount: dirtyFileCount
                )
            }
        }

        let fresh = try await listedWorktree(identity: worktree, on: host)
        guard !fresh.isMainWorktree else {
            throw WorktreeServiceError.mainWorktreeRemovalRefused(worktree.worktreePath)
        }
        guard !fresh.isLocked else {
            throw WorktreeServiceError.lockedWorktree(
                path: worktree.worktreePath,
                reason: fresh.lockReason
            )
        }

        var removeArguments = ["worktree", "remove"]
        if mode.forceWorktreeRemoval {
            removeArguments.append("--force")
        }
        removeArguments.append(worktree.worktreePath)

        var pruned = false
        var removal = await host.run(
            directory: worktree.repoPath,
            executable: "git",
            arguments: removeArguments,
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.addTimeout
        )
        if removal.executionError == nil,
           !removal.timedOut,
           removal.exitStatus != 0,
           isStaleAdministrativeError(commandMessage(removal)) {
            _ = try await prune(repoRoot: worktree.repoPath, on: host)
            pruned = true
            removal = await host.run(
                directory: worktree.repoPath,
                executable: "git",
                arguments: removeArguments,
                environment: WorktreeService.gitEnvironment,
                timeout: WorktreeService.addTimeout
            )
        }

        if removal.executionError != nil || removal.timedOut || removal.exitStatus != 0 {
            let message = commandMessage(removal)
            if isOrphanedGitDirectoryError(message) {
                throw WorktreeServiceError.orphanedGitDirectory(
                    path: worktree.worktreePath,
                    message: message
                )
            }
            _ = try successfulResult(
                removal,
                executable: "git",
                arguments: removeArguments,
                timeout: WorktreeService.addTimeout
            )
        }

        let cleanup = await cleanupBranch(
            fresh.branch,
            policy: mode.branchCleanup,
            repoRoot: fresh.identity.repoPath,
            on: host
        )
        return WorktreeRemovalResult(
            worktree: fresh.identity,
            branchCleanup: cleanup,
            prunedStaleAdministrativeData: pruned
        )
    }

    func dirtyFileCountForRemoval(
        worktree: WorktreeIdentity,
        on host: any WorktreeExecutionHost
    ) async throws -> Int {
        // Collapsed untracked directories keep this gate's output bounded;
        // the gate needs a clean/dirty verdict, not a per-file inventory.
        let result = try await runGit(
            on: host,
            directory: worktree.worktreePath,
            arguments: ["status", "--porcelain", "--untracked-files=normal"]
        )
        return (result.stdout ?? "").split(whereSeparator: \Character.isNewline).count
    }

    func cleanupBranch(
        _ branch: String?,
        policy: WorktreeBranchCleanup,
        repoRoot: String,
        on host: any WorktreeExecutionHost
    ) async -> WorktreeBranchCleanupResult {
        guard let branch else { return .notApplicable }
        switch policy {
        case .keep:
            return .preserved(branch: branch, reason: .requestedByCaller)
        case .deleteIfMerged:
            let result = await host.run(
                directory: repoRoot,
                executable: "git",
                arguments: ["branch", "-d", branch],
                environment: WorktreeService.gitEnvironment,
                timeout: WorktreeService.readTimeout
            )
            if result.executionError == nil, !result.timedOut, result.exitStatus == 0 {
                return .deleted(branch: branch)
            }
            let reason = commandMessage(result)
            return .preserved(
                branch: branch,
                reason: .deleteIfMergedRefused(message: reason.isEmpty ? nil : reason)
            )
        case let .forceDelete(expectedOID):
            let result = await host.run(
                directory: repoRoot,
                executable: "git",
                arguments: ["update-ref", "-d", "refs/heads/\(branch)", expectedOID],
                environment: WorktreeService.gitEnvironment,
                timeout: WorktreeService.readTimeout
            )
            if result.executionError == nil, !result.timedOut, result.exitStatus == 0 {
                // `git branch -d` also removes the branch's configuration
                // (upstream tracking plus the recorded lineage base) after
                // deleting the ref; mirror that here. Best effort, exactly
                // like Git's own non-atomic sequence.
                _ = await host.run(
                    directory: repoRoot,
                    executable: "git",
                    arguments: ["config", "--local", "--remove-section", "branch.\(branch)"],
                    environment: WorktreeService.gitEnvironment,
                    timeout: WorktreeService.readTimeout
                )
                return .deleted(branch: branch)
            }
            let detail = commandMessage(result)
            return .preserved(
                branch: branch,
                reason: .compareAndSwapRefused(message: detail.isEmpty ? nil : detail)
            )
        }
    }

    func isOrphanedGitDirectoryError(_ message: String) -> Bool {
        message.lowercased().contains("is not a working tree")
    }

    func isStaleAdministrativeError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        let staleMarkers = [
            "gitdir unreadable",
            "gitdir incorrect",
            "unable to read gitdir",
            "gitdir file",
            ".git file broken",
            "administrative files",
        ]
        return staleMarkers.contains(where: lowercased.contains)
    }
}
