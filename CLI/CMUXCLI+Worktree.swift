import CmuxWorktrees
import Foundation

extension CMUXCLI {
    func runWorktreeNamespace(commandArgs: [String], jsonOutput: Bool) async throws {
        var arguments = commandArgs
        let wantsJSON = jsonOutput || arguments.contains("--json")
        arguments.removeAll { $0 == "--json" }
        let subcommand = arguments.first?.lowercased() ?? "help"
        if !arguments.isEmpty {
            arguments.removeFirst()
        }

        let service = WorktreeService()
        let host = LocalWorktreeExecutionHost()
        switch subcommand {
        case "help":
            print(worktreeUsage())
        case "list", "ls":
            try await runWorktreeList(
                arguments: arguments,
                service: service,
                host: host,
                jsonOutput: wantsJSON
            )
        case "create", "new", "add":
            try await runWorktreeCreate(
                arguments: arguments,
                service: service,
                host: host,
                jsonOutput: wantsJSON
            )
        case "remove", "rm":
            try await runWorktreeRemove(
                arguments: arguments,
                service: service,
                host: host,
                jsonOutput: wantsJSON
            )
        case "prune":
            try await runWorktreePrune(
                arguments: arguments,
                service: service,
                host: host,
                jsonOutput: wantsJSON
            )
        case "status":
            try await runWorktreeStatus(
                arguments: arguments,
                service: service,
                host: host,
                jsonOutput: wantsJSON
            )
        default:
            throw CLIError(message: "Unknown worktree subcommand '\(subcommand)'. Run 'cmux worktree --help'.")
        }
    }

    func worktreeUsage() -> String {
        """
        Usage: cmux worktree <list|create|remove|prune|status> [options]

        Manage plain Git worktrees without requiring a running cmux app.

        Subcommands:
          list [--repo <path>] [--json]
          create [--repo <path>] [--name <name>] [--base <ref>] [--branch <branch>] [--path <path>] [--no-submodules] [--json]
          remove <path-or-name> [--force] [--keep-branch] [--json]
          prune [--repo <path>] [--json]
          status <path-or-name> [--json]

        Defaults:
          --repo    Current directory's Git repository root.
          --base    HEAD.
          --path    ~/.cmux/worktrees/<repo-name>/<name>.

        Create requires at least one of --name, --branch, or --path. Names and
        branch seeds are sanitized deterministically; no generated names are used.
        """
    }

    private func runWorktreeList(
        arguments: [String],
        service: WorktreeService,
        host: LocalWorktreeExecutionHost,
        jsonOutput: Bool
    ) async throws {
        var remaining = arguments
        let repo = try takeWorktreeOption("--repo", from: &remaining)
        try requireNoWorktreeArguments(remaining, usage: "cmux worktree list [--repo <path>]")
        let repoRoot = try await resolvedWorktreeRepository(
            repo,
            service: service,
            host: host
        )
        let worktrees = try await service.list(repoRoot: repoRoot, on: host)
        if jsonOutput {
            try printWorktreeJSON(worktrees)
            return
        }
        for worktree in worktrees {
            let marker = worktree.isMainWorktree ? "*" : " "
            let state: String
            if worktree.isBare {
                state = "bare"
            } else if worktree.isDetached {
                state = "detached"
            } else {
                state = worktree.branch ?? "unknown"
            }
            var suffixes: [String] = []
            if worktree.isLocked {
                suffixes.append("locked\(worktree.lockReason.map { ": \($0)" } ?? "")")
            }
            if worktree.isPrunable {
                suffixes.append("prunable\(worktree.prunableReason.map { ": \($0)" } ?? "")")
            }
            let suffix = suffixes.isEmpty ? "" : " [\(suffixes.joined(separator: "; "))]"
            print("\(marker) \(worktree.identity.worktreePath)\t\(state)\(suffix)")
        }
    }

    private func runWorktreeCreate(
        arguments: [String],
        service: WorktreeService,
        host: LocalWorktreeExecutionHost,
        jsonOutput: Bool
    ) async throws {
        var remaining = arguments
        let repo = try takeWorktreeOption("--repo", from: &remaining)
        let rawName = try takeWorktreeOption("--name", from: &remaining)
        let base = try takeWorktreeOption("--base", from: &remaining) ?? "HEAD"
        let branch = try takeWorktreeOption("--branch", from: &remaining)
        let path = try takeWorktreeOption("--path", from: &remaining)
        let initializeSubmodules = !takeWorktreeFlag("--no-submodules", from: &remaining)
        try requireNoWorktreeArguments(
            remaining,
            usage: "cmux worktree create [--repo <path>] --name <name> [--base <ref>] [--branch <branch>] [--path <path>]"
        )

        let name = rawName ?? branch.map { worktreeLeafName($0) } ?? path.map { worktreeLeafName($0) }
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError(message: "cmux worktree create requires --name, --branch, or --path")
        }
        let repoRoot = try await resolvedWorktreeRepository(
            repo,
            service: service,
            host: host
        )
        let worktree = try await service.create(
            repoRoot: repoRoot,
            name: name,
            baseRef: base,
            options: WorktreeCreateOptions(
                branchName: branch,
                worktreePath: path,
                initializeSubmodules: initializeSubmodules
            ),
            on: host
        )
        if jsonOutput {
            try printWorktreeJSON(worktree)
        } else {
            print(worktree.identity.worktreePath)
            for warning in worktree.warnings {
                cliWriteStderr("Warning: \(warning.message)\n")
            }
        }
    }

    private func runWorktreeRemove(
        arguments: [String],
        service: WorktreeService,
        host: LocalWorktreeExecutionHost,
        jsonOutput: Bool
    ) async throws {
        var remaining = arguments
        let force = takeWorktreeFlag("--force", from: &remaining)
        let keepBranch = takeWorktreeFlag("--keep-branch", from: &remaining)
        guard remaining.count == 1 else {
            throw CLIError(message: "Usage: cmux worktree remove <path-or-name> [--force] [--keep-branch]")
        }
        let repoRoot = try await resolvedWorktreeRepository(nil, service: service, host: host)
        let listed = try await service.list(repoRoot: repoRoot, on: host)
        let worktree = try resolvedWorktree(
            remaining[0],
            from: listed,
            currentDirectory: FileManager.default.currentDirectoryPath
        )
        let result = try await service.remove(
            worktree: worktree.identity,
            mode: WorktreeRemovalMode(
                forceWorktreeRemoval: force,
                branchCleanup: keepBranch ? .keep : .deleteIfMerged
            ),
            on: host
        )
        if jsonOutput {
            try printWorktreeJSON(result)
        } else {
            print("Removed \(result.worktree.worktreePath)")
            if case let .preserved(branch, reason) = result.branchCleanup {
                print("Preserved branch \(branch): \(reason)")
            }
        }
    }

    private func runWorktreePrune(
        arguments: [String],
        service: WorktreeService,
        host: LocalWorktreeExecutionHost,
        jsonOutput: Bool
    ) async throws {
        var remaining = arguments
        let repo = try takeWorktreeOption("--repo", from: &remaining)
        try requireNoWorktreeArguments(remaining, usage: "cmux worktree prune [--repo <path>]")
        let repoRoot = try await resolvedWorktreeRepository(repo, service: service, host: host)
        let result = try await service.prune(repoRoot: repoRoot, on: host)
        if jsonOutput {
            try printWorktreeJSON(result)
        } else {
            print(result.output.isEmpty ? "No stale worktree records." : result.output)
        }
    }

    private func runWorktreeStatus(
        arguments: [String],
        service: WorktreeService,
        host: LocalWorktreeExecutionHost,
        jsonOutput: Bool
    ) async throws {
        guard arguments.count == 1 else {
            throw CLIError(message: "Usage: cmux worktree status <path-or-name>")
        }
        let repoRoot = try await resolvedWorktreeRepository(nil, service: service, host: host)
        let listed = try await service.list(repoRoot: repoRoot, on: host)
        let worktree = try resolvedWorktree(
            arguments[0],
            from: listed,
            currentDirectory: FileManager.default.currentDirectoryPath
        )
        let status = try await service.status(worktree: worktree.identity, on: host)
        if jsonOutput {
            try printWorktreeJSON(status)
        } else {
            print("path: \(status.worktree.worktreePath)")
            print("branch: \(status.branch ?? "detached")")
            print("dirty files: \(status.dirtyFileCount)")
            if let upstream = status.upstream {
                print("upstream: \(upstream) (ahead \(status.aheadCount), behind \(status.behindCount))")
            }
            if let operation = status.operation {
                print("operation: \(operation.rawValue)")
            }
        }
    }

    private func resolvedWorktreeRepository(
        _ rawPath: String?,
        service: WorktreeService,
        host: LocalWorktreeExecutionHost
    ) async throws -> String {
        let path = rawPath.map(expandedWorktreePath) ?? FileManager.default.currentDirectoryPath
        return try await service.repositoryRoot(containing: path, on: host)
    }

    private func resolvedWorktree(
        _ raw: String,
        from worktrees: [WorktreeInfo],
        currentDirectory: String
    ) throws -> WorktreeInfo {
        let candidates: [WorktreeInfo]
        if raw.contains("/") || raw.hasPrefix("~") || raw == "." {
            let expanded = expandedWorktreePath(raw)
            let absolute = expanded.hasPrefix("/")
                ? expanded
                : (currentDirectory as NSString).appendingPathComponent(expanded)
            let normalized = canonicalLocalWorktreePath(absolute)
            candidates = worktrees.filter {
                canonicalLocalWorktreePath($0.identity.worktreePath) == normalized
            }
        } else {
            candidates = worktrees.filter {
                URL(fileURLWithPath: $0.identity.worktreePath).lastPathComponent == raw ||
                    $0.branch == raw
            }
        }
        guard candidates.count == 1, let match = candidates.first else {
            if candidates.isEmpty {
                throw CLIError(message: "No worktree matches '\(raw)'.")
            }
            throw CLIError(message: "Worktree name '\(raw)' is ambiguous; pass its full path.")
        }
        return match
    }

    private func takeWorktreeOption(_ name: String, from arguments: inout [String]) throws -> String? {
        var value: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("\(name)=") {
                guard value == nil else { throw CLIError(message: "Duplicate option \(name)") }
                value = String(argument.dropFirst(name.count + 1))
                arguments.remove(at: index)
            } else if argument == name {
                guard value == nil else { throw CLIError(message: "Duplicate option \(name)") }
                guard index + 1 < arguments.count else {
                    throw CLIError(message: "\(name) requires a value")
                }
                value = arguments[index + 1]
                arguments.removeSubrange(index ... index + 1)
            } else {
                index += 1
            }
        }
        return value
    }

    private func takeWorktreeFlag(_ name: String, from arguments: inout [String]) -> Bool {
        let existed = arguments.contains(name)
        arguments.removeAll { $0 == name }
        return existed
    }

    private func requireNoWorktreeArguments(_ arguments: [String], usage: String) throws {
        guard arguments.isEmpty else {
            throw CLIError(message: "Unexpected worktree argument '\(arguments[0])'. Usage: \(usage)")
        }
    }

    private func expandedWorktreePath(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath
    }

    private func canonicalLocalWorktreePath(_ raw: String) -> String {
        URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func worktreeLeafName(_ raw: String) -> String {
        URL(fileURLWithPath: raw).lastPathComponent
    }

    private func printWorktreeJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let output = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Could not encode worktree JSON output")
        }
        print(output)
    }
}
