import CmuxFoundation
import Foundation

extension WorktreeService {
    /// Creates a plain Git worktree and a new non-tracking branch.
    ///
    /// The add command is exactly `git worktree add --no-track -b <branch>
    /// <path> <base>`. Repository-local convenience config is best-effort and
    /// returned as warnings; submodule initialization failures are fatal but do
    /// not roll back the Git worktree that was already created.
    ///
    /// - Parameters:
    ///   - repoRoot: A host-local directory inside the source repository.
    ///   - name: The user-provided display/path name and default branch seed.
    ///   - baseRef: The commit-ish from which Git creates the branch.
    ///   - options: Optional branch prefix, branch seed, path, and submodule policy.
    ///   - host: The execution host.
    /// - Returns: A fresh Git snapshot plus any non-fatal config warnings.
    /// - Throws: ``WorktreeServiceError`` or a caller-supplied post-create hook error.
    public func create(
        repoRoot: String,
        name: String,
        baseRef: String,
        options: WorktreeCreateOptions = WorktreeCreateOptions(),
        on host: any WorktreeExecutionHost
    ) async throws -> WorktreeInfo {
        try await ensureAvailable(host)
        let invokingRepoRoot = try await repositoryRoot(containing: repoRoot, on: host)
        let existingWorktrees = try await list(repoRoot: invokingRepoRoot, on: host)
        let stableRepoRoot = existingWorktrees.first?.identity.repoPath ?? normalizedPath(repoRoot)

        let pathComponent = try sanitizedName(name)
        let branchSeed = try sanitizedName(options.branchName ?? name)
        let branch = (options.branchPrefix ?? "") + branchSeed
        try await validateBranch(branch, repoRoot: stableRepoRoot, on: host)
        let worktreePath = try resolvedCreatePath(
            repoRoot: invokingRepoRoot,
            defaultRepoRoot: stableRepoRoot,
            pathComponent: pathComponent,
            override: options.worktreePath,
            homeDirectory: host.homeDirectory
        )
        let lineageBaseRef = await resolvedLineageBaseRef(
            baseRef,
            repoRoot: invokingRepoRoot,
            on: host
        )

        // `--` keeps option-shaped base refs from being parsed as worktree
        // options; a literal `-` is normalized because Git's documented
        // `@{-1}` shorthand expansion happens during option parsing.
        _ = try await runGit(
            on: host,
            directory: invokingRepoRoot,
            arguments: [
                "worktree", "add", "--no-track", "-b", branch, "--",
                worktreePath, baseRef == "-" ? "@{-1}" : baseRef,
            ],
            timeout: WorktreeService.addTimeout
        )
        let canonicalWorktreePath = try await repositoryRoot(containing: worktreePath, on: host)

        let warnings = await configureCreatedBranch(
            branch: branch,
            baseRef: lineageBaseRef,
            repoRoot: stableRepoRoot,
            on: host
        )

        if options.initializeSubmodules {
            try await initializeSubmodulesIfNeeded(worktreePath: worktreePath, on: host)
        }

        let worktrees = try await list(repoRoot: stableRepoRoot, on: host)
        guard let created = worktrees.first(where: {
            samePath($0.identity.worktreePath, canonicalWorktreePath)
        }) else {
            throw WorktreeServiceError.worktreeNotFound(canonicalWorktreePath)
        }

        let context = WorktreePostCreateContext(worktree: created, baseRef: baseRef)
        for hook in postCreateHooks {
            try await hook.run(context: context, on: host)
        }
        return created.addingWarnings(warnings)
    }

    func sanitizedName(_ raw: String) throws -> String {
        var output = ""
        var needsSeparator = false
        for scalar in raw.unicodeScalars {
            if isUnicodeLetterOrNumber(scalar) {
                if needsSeparator, !output.isEmpty {
                    output.append("-")
                }
                output.unicodeScalars.append(scalar)
                needsSeparator = false
            } else if !output.isEmpty {
                needsSeparator = true
            }
        }

        let sanitized = output.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        guard !sanitized.isEmpty else {
            throw WorktreeServiceError.invalidName(raw)
        }
        return sanitized
    }

    func isUnicodeLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
             .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    func validateBranch(
        _ branch: String,
        repoRoot: String,
        on host: any WorktreeExecutionHost
    ) async throws {
        let result = await host.run(
            directory: repoRoot,
            executable: "git",
            arguments: ["check-ref-format", "--branch", branch],
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.readTimeout
        )
        guard result.executionError == nil, !result.timedOut, result.exitStatus == 0 else {
            throw WorktreeServiceError.invalidBranch(
                branch,
                reason: commandMessage(result).isEmpty ? "git check-ref-format rejected it" : commandMessage(result)
            )
        }
    }

    func resolvedCreatePath(
        repoRoot: String,
        defaultRepoRoot: String,
        pathComponent: String,
        override: String?,
        homeDirectory: String
    ) throws -> String {
        guard let override else {
            let repoName = defaultRepositoryName(defaultRepoRoot)
            return normalizedPath(
                (homeDirectory as NSString)
                    .appendingPathComponent(".cmux/worktrees/\(repoName)/\(pathComponent)")
            )
        }

        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw WorktreeServiceError.invalidPath(override)
        }

        let expanded: String
        if trimmed == "~" {
            expanded = homeDirectory
        } else if trimmed.hasPrefix("~/") {
            expanded = (homeDirectory as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        } else {
            expanded = trimmed
        }
        if expanded.hasPrefix("/") {
            return normalizedPath(expanded)
        }
        return normalizedPath((repoRoot as NSString).appendingPathComponent(expanded))
    }

    func defaultRepositoryName(_ repoRoot: String) -> String {
        var name = URL(fileURLWithPath: normalizedPath(repoRoot)).lastPathComponent
        if name.hasSuffix(".git") {
            name.removeLast(".git".count)
        }
        return name.isEmpty ? "repository" : name
    }

    func configureCreatedBranch(
        branch: String,
        baseRef: String,
        repoRoot: String,
        on host: any WorktreeExecutionHost
    ) async -> [WorktreeWarning] {
        var warnings: [WorktreeWarning] = []
        let existing = await host.run(
            directory: repoRoot,
            executable: "git",
            arguments: ["config", "--get", "push.autoSetupRemote"],
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.readTimeout
        )
        if existing.executionError == nil, !existing.timedOut, existing.exitStatus == 1 {
            let write = await host.run(
                directory: repoRoot,
                executable: "git",
                arguments: ["config", "--local", "push.autoSetupRemote", "true"],
                environment: WorktreeService.gitEnvironment,
                timeout: WorktreeService.readTimeout
            )
            if write.executionError != nil || write.timedOut || write.exitStatus != 0 {
                warnings.append(WorktreeWarning(
                    kind: .pushAutoSetupRemote,
                    message: commandMessage(write)
                ))
            }
        } else if existing.executionError != nil || existing.timedOut || ![0, 1].contains(existing.exitStatus) {
            warnings.append(WorktreeWarning(
                kind: .pushAutoSetupRemote,
                message: commandMessage(existing)
            ))
        }

        let lineage = await host.run(
            directory: repoRoot,
            executable: "git",
            arguments: ["config", "--local", WorktreeService.branchBaseConfigKey(for: branch), baseRef],
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.readTimeout
        )
        if lineage.executionError != nil || lineage.timedOut || lineage.exitStatus != 0 {
            warnings.append(WorktreeWarning(kind: .branchBase, message: commandMessage(lineage)))
        }
        return warnings
    }

    func resolvedLineageBaseRef(
        _ baseRef: String,
        repoRoot: String,
        on host: any WorktreeExecutionHost
    ) async -> String {
        // `git worktree add` accepts a bare `-` as `@{-1}`; the probes do not,
        // so normalize before resolving. `--end-of-options` keeps option-shaped
        // user input from being parsed as a rev-parse flag.
        let probeRef = baseRef == "-" ? "@{-1}" : baseRef
        let symbolic = await host.run(
            directory: repoRoot,
            executable: "git",
            arguments: ["rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", probeRef],
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.readTimeout
        )
        if symbolic.executionError == nil,
           !symbolic.timedOut,
           symbolic.exitStatus == 0,
           let ref = symbolic.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ref.isEmpty,
           ref != "HEAD" {
            for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
                return String(ref.dropFirst(prefix.count))
            }
            return ref
        }

        let commit = await host.run(
            directory: repoRoot,
            executable: "git",
            arguments: ["rev-parse", "--verify", "--end-of-options", "\(probeRef)^{commit}"],
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.readTimeout
        )
        if commit.executionError == nil,
           !commit.timedOut,
           commit.exitStatus == 0,
           let oid = commit.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
           !oid.isEmpty {
            return oid
        }
        return baseRef
    }

    func initializeSubmodulesIfNeeded(
        worktreePath: String,
        on host: any WorktreeExecutionHost
    ) async throws {
        let gitmodulesPath = (worktreePath as NSString).appendingPathComponent(".gitmodules")
        let exists = await host.run(
            directory: worktreePath,
            executable: "/bin/test",
            arguments: ["-f", gitmodulesPath],
            environment: [:],
            timeout: WorktreeService.readTimeout
        )
        guard exists.executionError == nil, !exists.timedOut else {
            _ = try successfulResult(
                exists,
                executable: "/bin/test",
                arguments: ["-f", gitmodulesPath],
                timeout: WorktreeService.readTimeout
            )
            return
        }
        if exists.exitStatus == 1 { return }
        guard exists.exitStatus == 0 else {
            _ = try successfulResult(
                exists,
                executable: "/bin/test",
                arguments: ["-f", gitmodulesPath],
                timeout: WorktreeService.readTimeout
            )
            return
        }

        let update = await host.run(
            directory: worktreePath,
            executable: "git",
            arguments: ["submodule", "update", "--init", "--recursive"],
            environment: WorktreeService.gitEnvironment,
            timeout: WorktreeService.addTimeout
        )
        guard update.executionError == nil, !update.timedOut, update.exitStatus == 0 else {
            throw WorktreeServiceError.submoduleInitializationFailed(
                path: worktreePath,
                message: commandMessage(update)
            )
        }
    }
}
