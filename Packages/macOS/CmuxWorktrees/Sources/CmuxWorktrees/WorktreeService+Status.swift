import Foundation

extension WorktreeService {
    /// Reads branch, dirty paths, upstream divergence, and in-progress operations.
    ///
    /// Status uses one `git status` call; ahead/behind counts come from the
    /// porcelain `branch.ab` header. Every Git read disables optional locks.
    ///
    /// - Parameters:
    ///   - worktree: The location-based worktree identity.
    ///   - host: The execution host matching the identity.
    /// - Returns: A cheap point-in-time status snapshot.
    /// - Throws: ``WorktreeServiceError`` when the host or a Git read fails.
    public func status(
        worktree: WorktreeIdentity,
        on host: any WorktreeExecutionHost
    ) async throws -> WorktreeStatus {
        try ensureIdentityHost(worktree, matches: host)
        try await ensureAvailable(host)
        // Fail closed on stale identities: a removed or moved worktree's path
        // may now belong to an unrelated repository.
        _ = try await listedWorktree(identity: worktree, on: host)

        // Collapsed untracked directories keep the buffered output bounded;
        // the snapshot reports a count, not a per-file inventory.
        let statusResult = try await runGit(
            on: host,
            directory: worktree.worktreePath,
            arguments: ["status", "--porcelain=v2", "--branch", "--untracked-files=normal"]
        )
        let parsed = parsedStatus(statusResult.stdout ?? "")

        return WorktreeStatus(
            worktree: worktree,
            branch: parsed.branch,
            dirtyFileCount: parsed.dirtyFileCount,
            upstream: parsed.upstream,
            aheadCount: parsed.ahead ?? 0,
            behindCount: parsed.behind ?? 0,
            isUpstreamGone: parsed.upstream != nil && parsed.ahead == nil,
            operation: try await inProgressOperation(worktree: worktree, on: host)
        )
    }

    func parsedStatus(
        _ output: String
    ) -> (branch: String?, upstream: String?, ahead: Int?, behind: Int?, dirtyFileCount: Int) {
        var branch: String?
        var upstream: String?
        var ahead: Int?
        var behind: Int?
        var dirtyFileCount = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                branch = value == "(detached)" ? nil : value
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                // `# branch.ab +<ahead> -<behind>`; emitted only while the
                // upstream commit is still resolvable.
                let fields = line.dropFirst("# branch.ab ".count)
                    .split(separator: " ")
                for field in fields {
                    if field.hasPrefix("+"), let value = Int(field.dropFirst()) {
                        ahead = value
                    } else if field.hasPrefix("-"), let value = Int(field.dropFirst()) {
                        behind = value
                    }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") ||
                        line.hasPrefix("u ") || line.hasPrefix("? ") {
                dirtyFileCount += 1
            }
        }
        return (branch, upstream, ahead, behind, dirtyFileCount)
    }

    func inProgressOperation(
        worktree: WorktreeIdentity,
        on host: any WorktreeExecutionHost
    ) async throws -> WorktreeOperation? {
        let gitDirectory = try await resolvedGitDirectory(worktree: worktree, on: host)
        let mergePath = (gitDirectory as NSString).appendingPathComponent("MERGE_HEAD")
        if try await pathExists(mergePath, directory: worktree.worktreePath, on: host) {
            return .merge
        }
        for component in ["rebase-merge", "rebase-apply"] {
            let rebasePath = (gitDirectory as NSString).appendingPathComponent(component)
            if try await pathExists(rebasePath, directory: worktree.worktreePath, on: host) {
                return .rebase
            }
        }
        return nil
    }

    func resolvedGitDirectory(
        worktree: WorktreeIdentity,
        on host: any WorktreeExecutionHost
    ) async throws -> String {
        let dotGit = (worktree.worktreePath as NSString).appendingPathComponent(".git")
        if try await pathExists(dotGit, directory: worktree.worktreePath, testFlag: "-d", on: host) {
            return dotGit
        }
        guard try await pathExists(dotGit, directory: worktree.worktreePath, testFlag: "-f", on: host) else {
            throw WorktreeServiceError.commandFailed(
                command: "inspect \(dotGit)",
                exitStatus: nil,
                message: "Git status succeeded, but the worktree's .git file is missing."
            )
        }

        let contents = await host.run(
            directory: worktree.worktreePath,
            executable: "/bin/cat",
            arguments: [dotGit],
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.readTimeout
        )
        _ = try successfulResult(
            contents,
            executable: "/bin/cat",
            arguments: [dotGit],
            timeout: WorktreeService.readTimeout
        )
        let line = contents.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = "gitdir:"
        guard line.hasPrefix(prefix) else {
            throw WorktreeServiceError.commandFailed(
                command: "parse \(dotGit)",
                exitStatus: nil,
                message: "The worktree's .git file has no gitdir entry."
            )
        }
        let rawPath = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if rawPath.hasPrefix("/") {
            return normalizedPath(rawPath)
        }
        return normalizedPath((worktree.worktreePath as NSString).appendingPathComponent(rawPath))
    }

    func pathExists(
        _ path: String,
        directory: String,
        testFlag: String = "-e",
        on host: any WorktreeExecutionHost
    ) async throws -> Bool {
        let result = await host.run(
            directory: directory,
            executable: "/bin/test",
            arguments: [testFlag, path],
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.readTimeout
        )
        if result.executionError == nil, !result.timedOut, result.exitStatus == 0 {
            return true
        }
        if result.executionError == nil, !result.timedOut, result.exitStatus == 1 {
            return false
        }
        _ = try successfulResult(
            result,
            executable: "/bin/test",
            arguments: [testFlag, path],
            timeout: WorktreeService.readTimeout
        )
        return false
    }
}
