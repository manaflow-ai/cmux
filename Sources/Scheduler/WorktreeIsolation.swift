import Foundation

/// Manages git worktree creation and cleanup for scheduler task isolation.
/// When enabled, each task run gets its own worktree so it cannot interfere
/// with the main working tree or other concurrent task runs.
enum WorktreeIsolation {

    /// Determines whether worktree isolation should be used for a given task.
    /// Per-task `useWorktree` overrides the global `schedulerWorktreeIsolation` setting.
    static func shouldUseWorktree(
        task: ScheduledTask,
        globalEnabled: Bool = SchedulerSettings.isWorktreeIsolationEnabled
    ) -> Bool {
        if let perTask = task.useWorktree {
            return perTask
        }
        return globalEnabled
    }

    /// Resolve the effective working directory for a task run.
    /// If worktree isolation is active and the directory is a git repo,
    /// creates a temporary worktree and returns its path.
    /// Otherwise returns the task's configured `workingDirectory` unchanged.
    ///
    /// - Parameters:
    ///   - task: The scheduled task.
    ///   - runId: The run ID (used to name the worktree branch).
    ///   - globalEnabled: Global worktree isolation setting.
    ///   - gitRunner: Injectable shell command runner for testing.
    /// - Returns: The effective working directory path (worktree or original).
    static func resolveWorkingDirectory(
        task: ScheduledTask,
        runId: UUID,
        globalEnabled: Bool = SchedulerSettings.isWorktreeIsolationEnabled,
        gitRunner: GitCommandRunner = ProcessGitCommandRunner()
    ) -> WorktreeResult {
        guard shouldUseWorktree(task: task, globalEnabled: globalEnabled),
              let workDir = task.workingDirectory else {
            return WorktreeResult(effectiveDirectory: task.workingDirectory, worktreePath: nil)
        }

        // Verify the directory is a git repository
        guard gitRunner.isGitRepository(at: workDir) else {
            return WorktreeResult(effectiveDirectory: workDir, worktreePath: nil)
        }

        // Create worktree in a scheduler-specific location
        let worktreeName = "scheduler-\(runId.uuidString.prefix(8))"
        let worktreeBase = (workDir as NSString).appendingPathComponent(".git/crux-worktrees")
        let worktreePath = (worktreeBase as NSString).appendingPathComponent(worktreeName)

        let branchName = "crux/scheduler/\(runId.uuidString.prefix(8))"

        if gitRunner.createWorktree(repoPath: workDir, worktreePath: worktreePath, branch: branchName) {
            return WorktreeResult(effectiveDirectory: worktreePath, worktreePath: worktreePath)
        }

        // Fallback to original directory if worktree creation fails
        return WorktreeResult(effectiveDirectory: workDir, worktreePath: nil)
    }

    /// Clean up a worktree after a task run completes.
    static func cleanupWorktree(
        repoPath: String,
        worktreePath: String,
        gitRunner: GitCommandRunner = ProcessGitCommandRunner()
    ) {
        gitRunner.removeWorktree(repoPath: repoPath, worktreePath: worktreePath)
    }
}

// MARK: - WorktreeResult

struct WorktreeResult: Equatable {
    /// The directory the task should run in (worktree path or original workingDirectory).
    let effectiveDirectory: String?
    /// Non-nil if a worktree was created (for cleanup after run completes).
    let worktreePath: String?
}

// MARK: - GitCommandRunner Protocol

/// Abstraction over git CLI commands for testability.
protocol GitCommandRunner {
    func isGitRepository(at path: String) -> Bool
    func createWorktree(repoPath: String, worktreePath: String, branch: String) -> Bool
    func removeWorktree(repoPath: String, worktreePath: String)
}

// MARK: - ProcessGitCommandRunner

/// Production implementation that shells out to `git`.
struct ProcessGitCommandRunner: GitCommandRunner {
    func isGitRepository(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--is-inside-work-tree"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func createWorktree(repoPath: String, worktreePath: String, branch: String) -> Bool {
        // Ensure parent directory exists
        let parentDir = (worktreePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parentDir,
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "worktree", "add", "-b", branch, worktreePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func removeWorktree(repoPath: String, worktreePath: String) {
        // Remove the worktree directory
        try? FileManager.default.removeItem(atPath: worktreePath)

        // Prune stale worktree references
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "worktree", "prune"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
