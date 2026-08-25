import Dispatch
import Foundation

/// Reads file-backed refs directly and delegates other storage backends to Git.
nonisolated struct SystemGitReferenceReader: GitReferenceReading {
    private static let maximumSymbolicReferenceByteCount = 16 * 1_024
    private static let maximumObjectIDByteCount = 128
    /// Configs above this bound use Git plumbing instead of an unbounded scan.
    private static let maximumReferenceStorageConfigByteCount = 1 * 1_024 * 1_024

    private let runnerSelector: GitReferenceRunnerSelector
    private let storageProbe: any GitReferenceStorageProbing
    private let configReader: GitConfigFileReader
    private let boundedCommandWallTimeLimit: TimeInterval

    /// Creates a production reader backed by the system Git executable.
    init(
        boundedCommandWallTimeLimit: TimeInterval = GitMetadataSafetyConfiguration().gitStatusWallTime,
        storageProbe: (any GitReferenceStorageProbing)? = nil,
        configReader: GitConfigFileReader = GitConfigFileReader(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runnerSelector = GitReferenceRunnerSelector(
            environment: environment,
            wallTimeLimit: boundedCommandWallTimeLimit
        )
        self.storageProbe = storageProbe ?? SystemGitReferenceStorageProbe()
        self.configReader = configReader
        self.boundedCommandWallTimeLimit = max(0, boundedCommandWallTimeLimit)
    }

    /// Creates a reader with an injected runner for deterministic tests.
    init(
        runner: any WorkspaceChangesGitRunning,
        storageProbe: (any GitReferenceStorageProbing)? = nil,
        configReader: GitConfigFileReader = GitConfigFileReader()
    ) {
        self.runnerSelector = GitReferenceRunnerSelector(runner: runner)
        self.storageProbe = storageProbe ?? SystemGitReferenceStorageProbe()
        self.configReader = configReader
        self.boundedCommandWallTimeLimit = GitMetadataSafetyConfiguration().gitStatusWallTime
    }

    /// Creates a reader with ordered injected runners for behavior tests.
    init(
        runners: [any WorkspaceChangesGitRunning],
        storageProbe: (any GitReferenceStorageProbing)? = nil,
        configReader: GitConfigFileReader = GitConfigFileReader()
    ) {
        self.runnerSelector = GitReferenceRunnerSelector(runners: runners)
        self.storageProbe = storageProbe ?? SystemGitReferenceStorageProbe()
        self.configReader = configReader
        self.boundedCommandWallTimeLimit = GitMetadataSafetyConfiguration().gitStatusWallTime
    }

    /// Resolves refs using direct files or Git plumbing according to storage.
    func snapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot {
        if hasReftableDirectory(repository: repository) {
            return plumbingSnapshot(repository: repository)
        }
        let directSnapshot = fileSnapshot(repository: repository)
        guard directSnapshot.currentCommit == nil || directSnapshot.branchName == ".invalid" else {
            return directSnapshot
        }
        let configuredStorage = referenceStorageName(repository: repository)
        if let configuredStorage, configuredStorage != "files" {
            return plumbingSnapshot(repository: repository)
        }
        if directSnapshot.branchName == ".invalid" {
            return GitReferenceSnapshot(
                checkedOutBranch: .unreadable,
                headSignature: nil,
                currentCommit: nil
            )
        }
        return directSnapshot
    }

    /// Reports whether this repository needs storage-independent Git plumbing.
    func requiresGitPlumbing(repository: ResolvedGitRepository) -> Bool {
        if hasReftableDirectory(repository: repository) {
            return true
        }
        // A valid file-backed HEAD already resolves its object ID without a
        // config scan. Only ambiguous/unborn/malformed heads need backend
        // detection, keeping ordinary sidebar refreshes on the direct path.
        if fileBackedHeadHasResolvedCommit(repository: repository) {
            return false
        }
        return referenceStorageName(repository: repository).map({ $0 != "files" }) == true
    }

    private func hasReftableDirectory(repository: ResolvedGitRepository) -> Bool {
        [repository.gitDirectory, repository.commonDirectory].contains { directory in
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent("reftable", isDirectory: true).path
            return storageProbe.isDirectory(atPath: path)
        }
    }

    /// Builds a snapshot from loose/packed reference files.
    private func fileSnapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot {
        let headSignature = GitMetadataService.gitHeadSignature(repository: repository)
        return GitReferenceSnapshot(
            checkedOutBranch: GitMetadataService.gitCheckedOutBranch(repository: repository),
            headSignature: headSignature,
            currentCommit: currentCommit(fromHeadSignature: headSignature)
        )
    }

    /// Builds a snapshot from Git's storage-independent plumbing commands.
    private func plumbingSnapshot(repository: ResolvedGitRepository) -> GitReferenceSnapshot {
        let deadline = DispatchTime.now() + boundedCommandWallTimeLimit
        guard let runner = runnerSelector.select(repository: repository, deadline: deadline) else {
            return GitReferenceSnapshot(
                checkedOutBranch: .unreadable,
                headSignature: nil,
                currentCommit: nil
            )
        }
        return plumbingSnapshot(repository: repository, runner: runner, deadline: deadline)
    }

    private func plumbingSnapshot(
        repository: ResolvedGitRepository,
        runner: any WorkspaceChangesGitRunning,
        deadline: DispatchTime
    ) -> GitReferenceSnapshot {
        let symbolicResult = commandOutput(
            arguments: ["symbolic-ref", "--quiet", "HEAD"],
            repository: repository,
            maximumByteCount: Self.maximumSymbolicReferenceByteCount,
            runner: runner,
            deadline: deadline
        )
        if case .failed = symbolicResult {
            return GitReferenceSnapshot(
                checkedOutBranch: .unreadable,
                headSignature: nil,
                currentCommit: nil
            )
        }
        let symbolicReference: String? = if case .value(let value) = symbolicResult {
            value
        } else {
            nil
        }

        if let symbolicReference, symbolicReference.hasPrefix("refs/heads/") {
            guard let stableReference = stableBranchReference(
                initialSymbolicReference: symbolicReference,
                repository: repository,
                runner: runner,
                deadline: deadline
            ),
            let branch = GitMetadataService.normalizedBranchName(
                String(stableReference.symbolicReference.dropFirst("refs/heads/".count))
            ) else {
                return GitReferenceSnapshot(
                    checkedOutBranch: .unreadable,
                    headSignature: nil,
                    currentCommit: nil
                )
            }
            return GitReferenceSnapshot(
                checkedOutBranch: .branch(branch),
                headSignature: "ref: \(stableReference.symbolicReference)\n\(stableReference.currentCommit ?? "")",
                currentCommit: stableReference.currentCommit,
                storageWatchPaths: storageWatchPaths(
                    repository: repository,
                    runner: runner,
                    deadline: deadline
                )
            )
        }

        let currentCommit = output(
            arguments: ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
            repository: repository,
            maximumByteCount: Self.maximumObjectIDByteCount,
            runner: runner,
            deadline: deadline
        ).flatMap { normalizedObjectID($0) }

        let checkedOutBranch: GitCheckedOutBranch
        if symbolicReference != nil || currentCommit != nil {
            checkedOutBranch = .detached
        } else {
            checkedOutBranch = .unreadable
        }

        let headSignature: String?
        if let symbolicReference {
            headSignature = "ref: \(symbolicReference)\n\(currentCommit ?? "")"
        } else {
            headSignature = currentCommit
        }
        return GitReferenceSnapshot(
            checkedOutBranch: checkedOutBranch,
            headSignature: headSignature,
            currentCommit: currentCommit,
            storageWatchPaths: storageWatchPaths(
                repository: repository,
                runner: runner,
                deadline: deadline
            )
        )
    }

    /// Resolves bounded Git path hints for custom reference storage.
    private func storageWatchPaths(
        repository: ResolvedGitRepository,
        runner: any WorkspaceChangesGitRunning,
        deadline: DispatchTime
    ) -> [String] {
        var paths: [String] = []
        for name in ["reftable", "refs", "packed-refs"] {
            guard let value = output(
                arguments: ["rev-parse", "--git-path", name],
                repository: repository,
                maximumByteCount: Self.maximumSymbolicReferenceByteCount,
                runner: runner,
                deadline: deadline
            ) else { continue }
            let path = value.hasPrefix("/")
                ? URL(fileURLWithPath: value).standardizedFileURL.path
                : URL(fileURLWithPath: repository.workTreeRoot)
                    .appendingPathComponent(value)
                    .standardizedFileURL.path
            paths.append(name == "reftable"
                ? URL(fileURLWithPath: path).appendingPathComponent("tables.list").path
                : path)
        }
        return paths
    }

    /// Resolves a branch ref and verifies that HEAD still names it afterward.
    private func stableBranchReference(
        initialSymbolicReference: String,
        repository: ResolvedGitRepository,
        runner: any WorkspaceChangesGitRunning,
        deadline: DispatchTime
    ) -> (symbolicReference: String, currentCommit: String?)? {
        var symbolicReference = initialSymbolicReference
        for _ in 0..<2 {
            let currentCommit = resolvedCommit(
                for: symbolicReference,
                repository: repository,
                runner: runner,
                deadline: deadline
            )
            if case .failed = currentCommit { return nil }
            guard let verifiedSymbolicReference = output(
                arguments: ["symbolic-ref", "--quiet", "HEAD"],
                repository: repository,
                maximumByteCount: Self.maximumSymbolicReferenceByteCount,
                runner: runner,
                deadline: deadline
            ) else {
                return nil
            }
            let verifiedCommit = resolvedCommit(
                for: verifiedSymbolicReference,
                repository: repository,
                runner: runner,
                deadline: deadline
            )
            if verifiedSymbolicReference == symbolicReference {
                if case let (.value(current), .value(verified)) = (currentCommit, verifiedCommit),
                   current == verified {
                    return (symbolicReference, current)
                }
                if currentCommit == .missing,
                   verifiedCommit == .missing,
                   isLegitimateUnbornReference(symbolicReference) {
                    // Git's reftable worktree compatibility HEAD uses the
                    // `.invalid` sentinel; never publish that value. A named
                    // branch with no object is the legitimate unborn case.
                    return (symbolicReference, nil)
                }
            }
            symbolicReference = verifiedSymbolicReference
            guard symbolicReference.hasPrefix("refs/heads/") else { return nil }
        }
        return nil
    }

    /// Returns true for a named branch that may legitimately have no commit.
    private func isLegitimateUnbornReference(_ symbolicReference: String) -> Bool {
        guard symbolicReference.hasPrefix("refs/heads/") else { return false }
        return String(symbolicReference.dropFirst("refs/heads/".count)) != ".invalid"
    }

    /// Resolves one branch ref while preserving missing-vs-failed outcomes.
    private func resolvedCommit(
        for symbolicReference: String,
        repository: ResolvedGitRepository,
        runner: any WorkspaceChangesGitRunning,
        deadline: DispatchTime
    ) -> GitReferenceCommandResult {
        let result = commandOutput(
            arguments: ["rev-parse", "--verify", "--quiet", "\(symbolicReference)^{commit}"],
            repository: repository,
            maximumByteCount: Self.maximumObjectIDByteCount,
            runner: runner,
            deadline: deadline
        )
        guard case .value(let value) = result else { return result }
        guard let normalized = normalizedObjectID(value) else { return .failed }
        return .value(normalized)
    }

    /// Runs one bounded plumbing command and returns trimmed UTF-8 output.
    private func output(
        arguments: [String],
        repository: ResolvedGitRepository,
        maximumByteCount: Int,
        runner: any WorkspaceChangesGitRunning,
        deadline: DispatchTime
    ) -> String? {
        guard case .value(let value) = commandOutput(
            arguments: arguments,
            repository: repository,
            maximumByteCount: maximumByteCount,
            runner: runner,
            deadline: deadline
        ) else { return nil }
        return value
    }

    /// Runs one bounded command and preserves missing-vs-failed outcomes.
    private func commandOutput(
        arguments: [String],
        repository: ResolvedGitRepository,
        maximumByteCount: Int,
        runner: any WorkspaceChangesGitRunning,
        deadline: DispatchTime
    ) -> GitReferenceCommandResult {
        let now = DispatchTime.now()
        guard deadline > now else { return .failed }
        let remainingNanoseconds = deadline.uptimeNanoseconds - now.uptimeNanoseconds
        let remainingSeconds = Double(remainingNanoseconds) / 1_000_000_000
        guard let result = try? runner.run(
            arguments: arguments,
            in: URL(fileURLWithPath: repository.workTreeRoot, isDirectory: true),
            maximumOutputByteCount: maximumByteCount,
            wallTimeLimit: remainingSeconds
        ),
        !result.standardOutputWasTruncated,
        let output = String(data: result.output, encoding: .utf8) else {
            return .failed
        }
        guard result.exitCode == 0 else {
            return result.exitCode == 1 ? .missing : .failed
        }
        guard let normalized = GitMetadataService.normalizedBranchName(output) else {
            return .failed
        }
        return .value(normalized)
    }

    /// Reads the local extensions.refStorage value, if one is declared.
    ///
    /// Root config files are size-bounded before decoding. An oversized config
    /// returns an unknown storage name, which conservatively selects Git
    /// plumbing rather than allowing repeated refreshes to scan unbounded data.
    private func referenceStorageName(repository: ResolvedGitRepository) -> String? {
        GitConfigBranchTraversal(
            repository: repository,
            branchContext: .fileBacked,
            configReader: configReader
        ).referenceStorageName()
    }

    /// Whether a file-backed HEAD already resolves to a complete object ID.
    private func fileBackedHeadHasResolvedCommit(repository: ResolvedGitRepository) -> Bool {
        let headURL = URL(fileURLWithPath: repository.gitDirectory)
            .appendingPathComponent("HEAD")
        guard let contents = try? String(contentsOf: headURL, encoding: .utf8) else {
            return false
        }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: ") else {
            return normalizedObjectID(trimmed) != nil
        }
        let refName = String(trimmed.dropFirst("ref: ".count))
        guard !refName.isEmpty,
              let value = GitMetadataService.gitRefValue(
                  repository: repository,
                  refName: refName
              ) else {
            return false
        }
        return normalizedObjectID(value) != nil
    }

    /// Reads at most the configured backend-detection limit from one config.
    nonisolated func boundedReferenceStorageConfig(
        at configURL: URL
    ) -> (contents: String?, isOversized: Bool) {
        switch configReader.read(
            at: configURL,
            maximumByteCount: Self.maximumReferenceStorageConfigByteCount
        ) {
        case .contents(let contents, consumedByteCount: _):
            return (contents, false)
        case .oversized(consumedByteCount: _):
            return (nil, true)
        case .missing:
            return (nil, false)
        case .unavailable(consumedByteCount: _):
            return (nil, false)
        }
    }

    /// Accepts only complete SHA-1 or SHA-256 object IDs.
    private func normalizedObjectID(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.count == 40 || normalized.count == 64,
              normalized.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return normalized
    }

    /// Extracts the resolved object ID from a file-backed head signature.
    private func currentCommit(fromHeadSignature signature: String?) -> String? {
        guard let signature else { return nil }
        if signature.hasPrefix("ref: ") {
            let lines = signature.components(separatedBy: "\n")
            guard lines.count == 2 else { return nil }
            return normalizedObjectID(lines[1])
        }
        return normalizedObjectID(signature)
    }
}
