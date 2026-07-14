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
        do {
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
                throw CLIError(message: worktreeLocalizedFormat(
                    "cli.worktree.error.unknownSubcommand",
                    defaultValue: "Unknown worktree subcommand '%@'. Run 'cmux worktree --help'.",
                    arguments: [subcommand]
                ))
            }
        } catch let error as WorktreeServiceError {
            throw CLIError(message: localizedWorktreeError(error))
        }
    }

    func worktreeUsage() -> String {
        String(localized: "cli.worktree.usage", defaultValue: """
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
        """)
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
                state = String(localized: "cli.worktree.state.bare", defaultValue: "bare")
            } else if worktree.isDetached {
                state = String(localized: "cli.worktree.state.detached", defaultValue: "detached")
            } else {
                state = worktree.branch ?? String(localized: "cli.worktree.state.unknown", defaultValue: "unknown")
            }
            var suffixes: [String] = []
            if worktree.isLocked {
                suffixes.append(worktree.lockReason.map {
                    worktreeLocalizedFormat(
                        "cli.worktree.state.lockedReason",
                        defaultValue: "locked: %@",
                        arguments: [$0]
                    )
                } ?? String(localized: "cli.worktree.state.locked", defaultValue: "locked"))
            }
            if worktree.isPrunable {
                suffixes.append(worktree.prunableReason.map {
                    worktreeLocalizedFormat(
                        "cli.worktree.state.prunableReason",
                        defaultValue: "prunable: %@",
                        arguments: [$0]
                    )
                } ?? String(localized: "cli.worktree.state.prunable", defaultValue: "prunable"))
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
            throw CLIError(message: String(
                localized: "cli.worktree.error.createIdentityRequired",
                defaultValue: "cmux worktree create requires --name, --branch, or --path"
            ))
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
                cliWriteStderr(localizedWorktreeWarning(warning) + "\n")
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
            throw CLIError(message: String(localized: "cli.worktree.error.removeUsage", defaultValue: "Usage: cmux worktree remove <path-or-name> [--force] [--keep-branch]"))
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
            print(worktreeLocalizedFormat(
                "cli.worktree.output.removed",
                defaultValue: "Removed %@",
                arguments: [result.worktree.worktreePath]
            ))
            if case let .preserved(branch, reason) = result.branchCleanup {
                print(worktreeLocalizedFormat(
                    "cli.worktree.output.preservedBranch",
                    defaultValue: "Preserved branch %@: %@",
                    arguments: [branch, localizedWorktreeBranchPreservationReason(reason)]
                ))
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
            print(result.output.isEmpty
                ? String(localized: "cli.worktree.output.noStaleRecords", defaultValue: "No stale worktree records.")
                : result.output)
        }
    }
    private func runWorktreeStatus(
        arguments: [String],
        service: WorktreeService,
        host: LocalWorktreeExecutionHost,
        jsonOutput: Bool
    ) async throws {
        guard arguments.count == 1 else {
            throw CLIError(message: String(localized: "cli.worktree.error.statusUsage", defaultValue: "Usage: cmux worktree status <path-or-name>"))
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
            print(worktreeLocalizedFormat(
                "cli.worktree.status.path",
                defaultValue: "path: %@",
                arguments: [status.worktree.worktreePath]
            ))
            print(worktreeLocalizedFormat(
                "cli.worktree.status.branch",
                defaultValue: "branch: %@",
                arguments: [status.branch ?? String(localized: "cli.worktree.state.detached", defaultValue: "detached")]
            ))
            print(worktreeLocalizedFormat(
                "cli.worktree.status.dirtyFiles",
                defaultValue: "dirty files: %lld",
                arguments: [Int64(status.dirtyFileCount)]
            ))
            if let upstream = status.upstream {
                print(worktreeLocalizedFormat(
                    "cli.worktree.status.upstream",
                    defaultValue: "upstream: %@ (ahead %lld, behind %lld)",
                    arguments: [upstream, Int64(status.aheadCount), Int64(status.behindCount)]
                ))
            }
            if let operation = status.operation {
                print(worktreeLocalizedFormat(
                    "cli.worktree.status.operation",
                    defaultValue: "operation: %@",
                    arguments: [operation.rawValue]
                ))
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
        if isWorktreePathArgument(raw) {
            let expanded = expandedWorktreePath(raw)
            let absolute = expanded.hasPrefix("/")
                ? expanded
                : (currentDirectory as NSString).appendingPathComponent(expanded)
            let normalized = canonicalLocalWorktreePath(absolute)
            candidates = Array(worktrees.filter {
                let root = canonicalLocalWorktreePath($0.identity.worktreePath)
                return normalized == root || root == "/" || normalized.hasPrefix(root + "/")
            }.sorted {
                canonicalLocalWorktreePath($0.identity.worktreePath).count > canonicalLocalWorktreePath($1.identity.worktreePath).count
            }.prefix(1))
        } else {
            candidates = worktrees.filter {
                URL(fileURLWithPath: $0.identity.worktreePath).lastPathComponent == raw ||
                    $0.branch == raw
            }
        }
        guard candidates.count == 1, let match = candidates.first else {
            if candidates.isEmpty {
                throw CLIError(message: worktreeLocalizedFormat(
                    "cli.worktree.error.noMatch",
                    defaultValue: "No worktree matches '%@'.",
                    arguments: [raw]
                ))
            }
            throw CLIError(message: worktreeLocalizedFormat(
                "cli.worktree.error.ambiguousName",
                defaultValue: "Worktree name '%@' is ambiguous; pass its full path.",
                arguments: [raw]
            ))
        }
        return match
    }

    private func takeWorktreeOption(_ name: String, from arguments: inout [String]) throws -> String? {
        var value: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("\(name)=") {
                guard value == nil else {
                    throw CLIError(message: worktreeLocalizedFormat(
                        "cli.worktree.error.duplicateOption",
                        defaultValue: "Duplicate option %@",
                        arguments: [name]
                    ))
                }
                value = String(argument.dropFirst(name.count + 1))
                arguments.remove(at: index)
            } else if argument == name {
                guard value == nil else {
                    throw CLIError(message: worktreeLocalizedFormat(
                        "cli.worktree.error.duplicateOption",
                        defaultValue: "Duplicate option %@",
                        arguments: [name]
                    ))
                }
                guard index + 1 < arguments.count else {
                    throw CLIError(message: worktreeLocalizedFormat(
                        "cli.worktree.error.optionRequiresValue",
                        defaultValue: "%@ requires a value",
                        arguments: [name]
                    ))
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
            throw CLIError(message: worktreeLocalizedFormat(
                "cli.worktree.error.unexpectedArgument",
                defaultValue: "Unexpected worktree argument '%@'. Usage: %@",
                arguments: [arguments[0], usage]
            ))
        }
    }
    private func expandedWorktreePath(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath
    }
    private func isWorktreePathArgument(_ raw: String) -> Bool {
        raw.contains("/") || raw.hasPrefix("~") || raw == "."
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
            throw CLIError(message: String(
                localized: "cli.worktree.error.jsonEncoding",
                defaultValue: "Could not encode worktree JSON output"
            ))
        }
        print(output)
    }
    private func localizedWorktreeWarning(_ warning: WorktreeWarning) -> String {
        let detail = warning.message.isEmpty ? String(localized: "cli.worktree.output.detailUnavailable", defaultValue: "no details available") : warning.message
        switch warning.kind {
        case .pushAutoSetupRemote:
            return worktreeLocalizedFormat("cli.worktree.warning.pushAutoSetupRemote", defaultValue: "Warning: Could not enable automatic upstream setup: %@", arguments: [detail])
        case .branchBase:
            return worktreeLocalizedFormat("cli.worktree.warning.branchBase", defaultValue: "Warning: Could not record branch lineage: %@", arguments: [detail])
        }
    }
    private func localizedWorktreeBranchPreservationReason(_ reason: WorktreeBranchPreservationReason) -> String {
        switch reason {
        case .requestedByCaller:
            return String(localized: "cli.worktree.branchPreservation.requested", defaultValue: "requested by caller")
        case let .deleteIfMergedRefused(message):
            return message.map { worktreeLocalizedFormat("cli.worktree.branchPreservation.deleteRefusedMessage", defaultValue: "git branch -d refused deletion: %@", arguments: [$0]) }
                ?? String(localized: "cli.worktree.branchPreservation.deleteRefused", defaultValue: "git branch -d refused deletion")
        case let .compareAndSwapRefused(message):
            return message.map { worktreeLocalizedFormat("cli.worktree.branchPreservation.compareAndSwapRefusedMessage", defaultValue: "branch moved; compare-and-swap deletion refused: %@", arguments: [$0]) }
                ?? String(localized: "cli.worktree.branchPreservation.compareAndSwapRefused", defaultValue: "branch moved; compare-and-swap deletion refused")
        }
    }

    private func localizedWorktreeError(_ error: WorktreeServiceError) -> String {
        switch error {
        case let .hostUnavailable(host):
            return worktreeLocalizedFormat("cli.worktree.serviceError.hostUnavailable", defaultValue: "Execution host '%@' is unavailable.", arguments: [host.rawValue])
        case let .hostMismatch(expected, actual):
            return worktreeLocalizedFormat("cli.worktree.serviceError.hostMismatch", defaultValue: "Worktree belongs to host '%@', not '%@'.", arguments: [expected.rawValue, actual.rawValue])
        case let .invalidName(name):
            return worktreeLocalizedFormat("cli.worktree.serviceError.invalidName", defaultValue: "Worktree name '%@' does not contain a Unicode letter or number.", arguments: [name])
        case let .invalidBranch(branch, reason):
            return worktreeLocalizedFormat("cli.worktree.serviceError.invalidBranch", defaultValue: "Invalid branch '%@': %@", arguments: [branch, reason])
        case let .invalidPath(path):
            return worktreeLocalizedFormat("cli.worktree.serviceError.invalidPath", defaultValue: "Invalid worktree path '%@'; path traversal is not allowed.", arguments: [path])
        case let .worktreeNotFound(path):
            return worktreeLocalizedFormat("cli.worktree.serviceError.worktreeNotFound", defaultValue: "Git does not report a worktree at '%@'.", arguments: [path])
        case let .mainWorktreeRemovalRefused(path):
            return worktreeLocalizedFormat("cli.worktree.serviceError.mainRemovalRefused", defaultValue: "Refusing to remove the main worktree at '%@'.", arguments: [path])
        case let .dirtyWorktree(path, fileCount):
            return worktreeLocalizedFormat("cli.worktree.serviceError.dirtyWorktree", defaultValue: "Refusing to remove dirty worktree '%@' (%lld changed path(s)); pass --force to discard them.", arguments: [path, Int64(fileCount)])
        case let .lockedWorktree(path, reason):
            if let reason {
                return worktreeLocalizedFormat("cli.worktree.serviceError.lockedWorktreeReason", defaultValue: "Refusing to remove locked worktree '%@': %@", arguments: [path, reason])
            }
            return worktreeLocalizedFormat("cli.worktree.serviceError.lockedWorktree", defaultValue: "Refusing to remove locked worktree '%@'.", arguments: [path])
        case let .orphanedGitDirectory(path, message):
            return worktreeLocalizedFormat("cli.worktree.serviceError.orphanedGitDirectory", defaultValue: "Git reports '%@' is not a working tree; prune its orphaned administrative entry instead. %@", arguments: [path, message])
        case let .commandTimedOut(command, seconds):
            return worktreeLocalizedFormat("cli.worktree.serviceError.commandTimedOut", defaultValue: "Command timed out after %llds: %@", arguments: [Int64(seconds), command])
        case let .commandFailed(command, exitStatus, message):
            let status = exitStatus.map(String.init)
                ?? String(localized: "cli.worktree.serviceError.statusUnavailable", defaultValue: "unavailable")
            return worktreeLocalizedFormat("cli.worktree.serviceError.commandFailed", defaultValue: "Command failed (status %@): %@\n%@", arguments: [status, command, message])
        case let .submoduleInitializationFailed(path, message):
            return worktreeLocalizedFormat("cli.worktree.serviceError.submoduleInitializationFailed", defaultValue: "Worktree was created at '%@', but submodule initialization failed: %@", arguments: [path, message])
        }
    }

    private func worktreeLocalizedFormat(_ key: StaticString, defaultValue: String.LocalizationValue, arguments: [any CVarArg]) -> String {
        String(format: String(localized: key, defaultValue: defaultValue), arguments: arguments)
    }
}
