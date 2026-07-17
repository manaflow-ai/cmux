import CmuxFoundation
import CmuxGit
import Foundation

/// App-side Git implementation used until the dedicated CmuxWorktrees package lands.
actor WorktreeSidebarGitService: WorktreeSidebarGitOperating {
    private let commands: any CommandRunning
    private let metadata: GitMetadataService
    private let parser: WorktreeSidebarPorcelainParser
    private let gitEnvironment = WorktreeSidebarGitEnvironment()
    private let commandTimeout: TimeInterval
    private let submoduleTimeout: TimeInterval

    init(
        commands: any CommandRunning = CommandRunner(),
        metadata: GitMetadataService = GitMetadataService(),
        parser: WorktreeSidebarPorcelainParser = WorktreeSidebarPorcelainParser(),
        commandTimeout: TimeInterval = 30,
        submoduleTimeout: TimeInterval = 300
    ) {
        self.commands = commands
        self.metadata = metadata
        self.parser = parser
        self.commandTimeout = commandTimeout
        self.submoduleTimeout = submoduleTimeout
    }

    func listWorktrees(projectRootPath: String) async throws -> [WorktreeSidebarWorktree] {
        let output = try await checkedGit(
            projectRootPath: projectRootPath,
            arguments: ["worktree", "list", "--porcelain", "-z", "--expire", "now"],
            operation: .list,
            optionalLocks: true
        )
        return parser.parse(output)
    }

    func isDirty(
        projectRootPath: String,
        worktreePath: String
    ) async throws -> Bool {
        try await WorktreeSidebarBoundedGitProbe(
            commands: commands,
            timeout: commandTimeout
        ).hasVisibleChanges(
            commandDirectory: projectRootPath,
            worktreePath: worktreePath
        )
    }

    func inspectDeletion(
        projectRootPath: String,
        worktreePath: String
    ) async throws -> WorktreeSidebarDeletionInspection {
        let worktrees = try await listWorktrees(projectRootPath: projectRootPath)
        let normalizedTarget = WorktreeSidebarWorktree.normalizedPath(worktreePath)
        guard let worktree = worktrees.first(where: { $0.normalizedPath == normalizedTarget }) else {
            throw WorktreeSidebarGitError.worktreeNotFound
        }
        guard !worktree.isMain else {
            throw WorktreeSidebarGitError.mainWorktree
        }
        guard !worktree.isLocked else {
            throw WorktreeSidebarGitError.locked(reason: worktree.lockReason)
        }
        guard !worktrees.contains(where: { worktree.isAncestor(of: $0) }) else {
            throw WorktreeSidebarGitError.containsRegisteredWorktrees
        }

        let status = try await deletionStatus(
            projectRootPath: projectRootPath,
            worktree: worktree
        )
        let localBranch = try await localBranch(
            projectRootPath: projectRootPath,
            worktree: worktree
        )
        let unpushedCommitCount = try await unpushedCommitCount(
            projectRootPath: projectRootPath,
            worktree: worktree,
            localBranch: localBranch
        )
        let branchDisposition = try await branchDisposition(
            projectRootPath: projectRootPath,
            localBranch: localBranch
        )
        let hasInitializedSubmodules = worktree.isPrunable
            ? false
            : try await hasInitializedSubmodules(
                projectRootPath: projectRootPath,
                worktreePath: worktree.path
            )
        return WorktreeSidebarDeletionInspection(
            worktree: worktree,
            statusFingerprint: status.statusFingerprint,
            ignoredFingerprint: status.ignoredFingerprint,
            hasUncommittedChanges: status.hasUncommittedChanges,
            hasIgnoredFiles: status.hasIgnoredFiles,
            unpushedCommitCount: unpushedCommitCount,
            branchDisposition: branchDisposition,
            hasInitializedSubmodules: hasInitializedSubmodules
        )
    }

    func removeWorktree(
        projectRootPath: String,
        expected: WorktreeSidebarDeletionInspection,
        force: Bool
    ) async throws -> WorktreeSidebarDeletionResult {
        // This fresh inspection is the final lock/state check. Comparing the
        // Git-reported risk snapshot catches path/state changes without hashing
        // arbitrarily large, actively changing build output after force consent.
        let current = try await inspectDeletion(
            projectRootPath: projectRootPath,
            worktreePath: expected.worktree.path
        )
        guard current == expected else {
            throw WorktreeSidebarGitError.worktreeChanged
        }
        guard force || !current.requiresForceRemoval else {
            throw WorktreeSidebarGitError.forceRequired
        }

        let removal: WorktreeSidebarDeletionResult.Removal
        if current.worktree.isPrunable {
            try await removeStaleRegistration(
                projectRootPath: projectRootPath,
                worktreePath: current.worktree.path
            )
            removal = .pruned
        } else {
            var arguments = ["worktree", "remove"]
            if force { arguments.append("--force") }
            arguments.append(current.worktree.path)
            let result = await git(
                projectRootPath: projectRootPath,
                arguments: arguments,
                optionalLocks: false
            )
            if result.worktreeSidebarSucceeded {
                removal = .removed
            } else if result.worktreeSidebarDetails.localizedCaseInsensitiveContains("is not a working tree") {
                throw WorktreeSidebarGitError.worktreeChanged
            } else {
                throw WorktreeSidebarGitError.commandFailed(
                    .remove,
                    details: result.worktreeSidebarDetails
                )
            }
        }

        let branch = await deleteBranchIfSafe(
            projectRootPath: projectRootPath,
            disposition: current.branchDisposition
        )
        return WorktreeSidebarDeletionResult(removal: removal, branch: branch)
    }

    func createWorktree(
        projectRootPath: String,
        userInput: String
    ) async throws -> WorktreeSidebarCreationResult {
        guard let branch = WorktreeSidebarBranchName(userInput: userInput) else {
            throw WorktreeSidebarGitError.invalidBranchName(userInput)
        }
        let validation = await git(
            projectRootPath: projectRootPath,
            arguments: ["check-ref-format", "--branch", branch.value],
            optionalLocks: true
        )
        guard validation.worktreeSidebarSucceeded else {
            throw WorktreeSidebarGitError.invalidBranchName(branch.value)
        }

        try await ensureCmuxDirectoryIsIgnored(projectRootPath: projectRootPath)
        let root = URL(fileURLWithPath: projectRootPath, isDirectory: true)
            .standardizedFileURL
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let worktree = root.appendingPathComponent(branch.value, isDirectory: true)
        let creation = WorktreeSidebarCreationResult(
            branchName: branch.value,
            worktreePath: worktree.path
        )

        _ = try await checkedGit(
            projectRootPath: projectRootPath,
            arguments: [
                "worktree", "add", "--no-track", "-b", branch.value,
                worktree.path, "HEAD",
            ],
            operation: .create,
            optionalLocks: false
        )

        let gitmodules = URL(fileURLWithPath: worktree.path, isDirectory: true)
            .appendingPathComponent(".gitmodules", isDirectory: false)
        if FileManager.default.fileExists(atPath: gitmodules.path) {
            let submodules = await git(
                projectRootPath: worktree.path,
                arguments: ["submodule", "update", "--init", "--recursive"],
                optionalLocks: false,
                timeout: submoduleTimeout
            )
            guard submodules.worktreeSidebarSucceeded else {
                throw WorktreeSidebarGitError.submoduleInitializationFailed(
                    creation,
                    details: submodules.worktreeSidebarDetails
                )
            }
        }
        return creation
    }

    func listingWatchPlan(projectRootPath: String) async -> WorktreeSidebarListingWatchPlan {
        guard let rawCommonDirectory = try? await checkedGit(
            projectRootPath: projectRootPath,
            arguments: ["rev-parse", "--git-common-dir"],
            operation: .list,
            optionalLocks: true
        ).trimmingCharacters(in: .whitespacesAndNewlines),
              !rawCommonDirectory.isEmpty else {
            let marker = URL(fileURLWithPath: projectRootPath, isDirectory: true)
                .appendingPathComponent(".git", isDirectory: false)
            return FileManager.default.fileExists(atPath: marker.path)
                ? WorktreeSidebarListingWatchPlan(
                    membershipDirectory: nil,
                    metadataPaths: [marker.path]
                )
                : .empty
        }

        let projectRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true)
        let commonDirectory = URL(
            fileURLWithPath: rawCommonDirectory,
            relativeTo: projectRoot
        ).standardizedFileURL
        return WorktreeSidebarListingWatchPathResolver().makePlan(
            commonDirectory: commonDirectory.path
        )
    }

    func statusWatchPlan(
        worktreePath: String,
        excludingWorktreePaths: [String]
    ) async -> WorktreeSidebarStatusWatchPlan {
        guard let paths = await metadata.watchedPaths(for: worktreePath),
              let rawGitDirectory = try? await checkedGit(
                  projectRootPath: worktreePath,
                  arguments: ["rev-parse", "--absolute-git-dir"],
                  operation: .status,
                  optionalLocks: true
              ) else { return .empty }
        let gitDirectory = rawGitDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorktreeSidebarStatusWatchPlanner().makePlan(
            worktreePath: worktreePath,
            gitDirectory: gitDirectory,
            metadataPaths: paths,
            excludedWorktreePaths: excludingWorktreePaths
        )
    }

    private func deletionStatus(
        projectRootPath: String,
        worktree: WorktreeSidebarWorktree
    ) async throws -> WorktreeSidebarDeletionStatusSnapshot {
        guard !worktree.isPrunable else { return WorktreeSidebarDeletionStatusSnapshot() }
        let probe = WorktreeSidebarBoundedGitProbe(
            commands: commands,
            timeout: commandTimeout
        )
        let statusFingerprint = try await probe.deletionChangesFingerprint(
            commandDirectory: projectRootPath,
            worktreePath: worktree.path
        )
        let ignored = try await probe.ignoredFilesSnapshot(
            commandDirectory: projectRootPath,
            worktreePath: worktree.path
        )
        return WorktreeSidebarDeletionStatusSnapshot(
            statusFingerprint: statusFingerprint,
            ignoredFingerprint: ignored.fingerprint,
            hasUncommittedChanges: statusFingerprint.hasContent,
            hasIgnoredFiles: ignored.hasContent
        )
    }

    private func unpushedCommitCount(
        projectRootPath: String,
        worktree: WorktreeSidebarWorktree,
        localBranch: WorktreeSidebarLocalBranch?
    ) async throws -> Int {
        guard let revision = localBranch?.ref ?? worktree.head,
              !revision.isEmpty else {
            return 0
        }
        var arguments = [
            "rev-list", "--count", revision,
            "--not", "HEAD", "--remotes",
        ]
        if let localBranch {
            arguments.append("--exclude=\(localBranch.name)")
        }
        arguments.append("--branches")
        let output = try await checkedGit(
            projectRootPath: projectRootPath,
            arguments: arguments,
            operation: .inspect,
            optionalLocks: true
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(output) else {
            throw WorktreeSidebarGitError.commandFailed(.inspect, details: output)
        }
        return count
    }

    private func branchDisposition(
        projectRootPath: String,
        localBranch: WorktreeSidebarLocalBranch?
    ) async throws -> WorktreeSidebarDeletionInspection.BranchDisposition {
        guard let localBranch else { return .noLocalBranch }
        let result = await git(
            projectRootPath: projectRootPath,
            arguments: [
                "merge-base", "--is-ancestor",
                localBranch.ref,
                localBranch.upstreamRef ?? "HEAD",
            ],
            optionalLocks: true
        )
        if result.worktreeSidebarSucceeded { return .deleteMerged(localBranch.name) }
        if result.executionError == nil, !result.timedOut, result.exitStatus == 1 {
            return .keepUnmerged(localBranch.name)
        }
        throw WorktreeSidebarGitError.commandFailed(.inspect, details: result.worktreeSidebarDetails)
    }

    private func localBranch(
        projectRootPath: String,
        worktree: WorktreeSidebarWorktree
    ) async throws -> WorktreeSidebarLocalBranch? {
        guard let branchRef = worktree.branchRef,
              let branchName = worktree.branchName else {
            return nil
        }
        let output = try await checkedGit(
            projectRootPath: projectRootPath,
            arguments: [
                "for-each-ref", "--format=%(refname)%00%(upstream)", branchRef,
            ],
            operation: .inspect,
            optionalLocks: true
        )
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.first.map(String.init) == branchRef else { continue }
            let upstream = fields.count > 1 ? String(fields[1]) : ""
            return WorktreeSidebarLocalBranch(
                name: branchName,
                ref: branchRef,
                upstreamRef: upstream.isEmpty ? nil : upstream
            )
        }
        return nil
    }

    private func hasInitializedSubmodules(
        projectRootPath: String,
        worktreePath: String
    ) async throws -> Bool {
        let output = try await checkedGit(
            projectRootPath: projectRootPath,
            arguments: ["-C", worktreePath, "submodule", "status", "--recursive"],
            operation: .inspect,
            optionalLocks: true
        )
        return output.split(whereSeparator: \.isNewline).contains { line in
            !line.isEmpty && line.first != "-"
        }
    }

    private func deleteBranchIfSafe(
        projectRootPath: String,
        disposition: WorktreeSidebarDeletionInspection.BranchDisposition
    ) async -> WorktreeSidebarDeletionResult.Branch {
        let branchName: String
        switch disposition {
        case .deleteMerged(let name), .keepUnmerged(let name):
            branchName = name
        case .noLocalBranch:
            return .notApplicable
        }
        let result = await git(
            projectRootPath: projectRootPath,
            arguments: ["branch", "-d", "--", branchName],
            optionalLocks: false
        )
        return result.worktreeSidebarSucceeded
            ? .deleted(branchName)
            : .preserved(branchName, reason: result.worktreeSidebarDetails)
    }

    private func removeStaleRegistration(
        projectRootPath: String,
        worktreePath: String
    ) async throws {
        _ = try await checkedGit(
            projectRootPath: projectRootPath,
            arguments: ["worktree", "remove", worktreePath],
            operation: .prune,
            optionalLocks: false
        )
    }

    private func ensureCmuxDirectoryIsIgnored(projectRootPath: String) async throws {
        let rawPath = try await checkedGit(
            projectRootPath: projectRootPath,
            arguments: ["rev-parse", "--git-path", "info/exclude"],
            operation: .create,
            optionalLocks: true
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            throw WorktreeSidebarGitError.commandFailed(.create, details: "")
        }
        let projectRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true)
        let exclude = URL(fileURLWithPath: rawPath, relativeTo: projectRoot).standardizedFileURL
        try FileManager.default.createDirectory(
            at: exclude.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = (try? Data(contentsOf: exclude))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let alreadyIgnored = existing
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { $0 == ".cmux" || $0 == ".cmux/" }
        guard !alreadyIgnored else { return }

        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let updated = existing + separator + ".cmux/\n"
        try Data(updated.utf8).write(to: exclude, options: .atomic)
    }

    private func checkedGit(
        projectRootPath: String,
        arguments: [String],
        operation: WorktreeSidebarGitError.Operation,
        optionalLocks: Bool
    ) async throws -> String {
        let result = await git(
            projectRootPath: projectRootPath,
            arguments: arguments,
            optionalLocks: optionalLocks
        )
        guard result.worktreeSidebarSucceeded else {
            throw WorktreeSidebarGitError.commandFailed(operation, details: result.worktreeSidebarDetails)
        }
        return result.stdout ?? ""
    }

    private func git(
        projectRootPath: String,
        arguments: [String],
        optionalLocks: Bool,
        timeout: TimeInterval? = nil
    ) async -> CommandResult {
        let timeout = timeout ?? commandTimeout
        return await commands.run(
            directory: projectRootPath,
            executable: "/usr/bin/env",
            arguments: gitEnvironment.launchArguments(
                executable: "/usr/bin/git",
                arguments: ["-C", projectRootPath] + arguments,
                optionalLocks: optionalLocks
            ),
            timeout: timeout
        )
    }

}
