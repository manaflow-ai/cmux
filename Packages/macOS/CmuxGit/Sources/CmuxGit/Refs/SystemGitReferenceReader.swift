import Dispatch
import Foundation

/// Reads file-backed refs directly and delegates other storage backends to Git.
nonisolated struct SystemGitReferenceReader: GitReferenceReading {
    static let maximumSymbolicReferenceByteCount = 16 * 1_024
    private static let maximumObjectIDByteCount = 128
    /// Configs above this bound use Git plumbing instead of an unbounded scan.
    private static let maximumReferenceStorageConfigByteCount = 1 * 1_024 * 1_024
    private let runnerSelector: GitReferenceRunnerSelector
    let storageProbe: any GitReferenceStorageProbing
    let configReader: GitConfigFileReader
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
        snapshot(repository: repository, deadline: nil, includeStorageWatchPaths: false)
    }

    /// Resolves refs without extending an aggregate caller deadline.
    func snapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?
    ) -> GitReferenceSnapshot {
        snapshot(repository: repository, deadline: deadline, includeStorageWatchPaths: false)
    }

    /// Resolves refs and optionally derives backend paths for a watcher.
    func snapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?,
        includeStorageWatchPaths: Bool
    ) -> GitReferenceSnapshot {
        let deadline = deadline ?? (DispatchTime.now() + boundedCommandWallTimeLimit)
        guard deadline > DispatchTime.now() else {
            return unreadableSnapshot()
        }
        if hasReftableDirectory(repository: repository, deadline: deadline) {
            return plumbingSnapshot(
                repository: repository,
                deadline: deadline,
                includeStorageWatchPaths: includeStorageWatchPaths
            )
        }
        guard let directSnapshot = boundedFileSnapshot(
            repository: repository,
            deadline: deadline
        ) else {
            return plumbingSnapshot(
                repository: repository,
                deadline: deadline,
                includeStorageWatchPaths: includeStorageWatchPaths
            )
        }
        let quickProbe = quickReferenceStorageName(repository: repository, deadline: deadline)
        if directSnapshot.currentCommit != nil,
           directSnapshot.branchName != ".invalid" {
            switch quickProbe {
            case .complete(let storage):
                if let storage, storage != "files" {
                    return plumbingSnapshot(
                        repository: repository,
                        deadline: deadline,
                        includeStorageWatchPaths: includeStorageWatchPaths
                    )
                }
                return directSnapshot
            case .incomplete:
                // A root include does not imply a non-files backend. Finish
                // the same bounded include walk with the resolved branch
                // context before paying for Git plumbing; ordinary files
                // repositories then stay on the direct hot path.
                let storage = referenceStorageName(
                    repository: repository,
                    branchContext: .resolved(directSnapshot.branchName),
                    deadline: deadline
                )
                if let storage, storage != "files" {
                    return plumbingSnapshot(
                        repository: repository,
                        deadline: deadline,
                        includeStorageWatchPaths: includeStorageWatchPaths
                    )
                }
                return directSnapshot
            }
        }
        let configuredStorage: String?
        switch quickProbe {
        case .complete(let storage):
            configuredStorage = storage
        case .incomplete:
            guard directSnapshot.branchName != ".invalid" else {
                return plumbingSnapshot(
                    repository: repository,
                    deadline: deadline,
                    includeStorageWatchPaths: includeStorageWatchPaths
                )
            }
            configuredStorage = referenceStorageName(
                repository: repository,
                branchContext: .resolved(directSnapshot.branchName),
                deadline: deadline
            )
        }
        if let configuredStorage, configuredStorage != "files" {
            return plumbingSnapshot(
                repository: repository,
                deadline: deadline,
                includeStorageWatchPaths: includeStorageWatchPaths
            )
        }
        guard directSnapshot.currentCommit == nil || directSnapshot.branchName == ".invalid" else {
            return directSnapshot
        }
        let configuredStorage = configuredStorage
            ?? referenceStorageName(
                repository: repository,
                branchContext: .resolved(directSnapshot.branchName),
                deadline: deadline
            )
        if let configuredStorage, configuredStorage != "files" {
            return plumbingSnapshot(
                repository: repository,
                deadline: deadline,
                includeStorageWatchPaths: includeStorageWatchPaths
            )
        }
        if directSnapshot.branchName == ".invalid" {
            return unreadableSnapshot()
        }
        return directSnapshot
    }

    /// Reports whether this repository needs storage-independent Git plumbing.
    func requiresGitPlumbing(repository: ResolvedGitRepository) -> Bool {
        requiresGitPlumbing(repository: repository, deadline: nil)
    }

    /// Reports whether plumbing is needed without extending an aggregate deadline.
    func requiresGitPlumbing(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?
    ) -> Bool {
        if let deadline, deadline <= DispatchTime.now() {
            return true
        }
        if hasReftableDirectory(repository: repository, deadline: deadline) {
            return true
        }
        let effectiveDeadline = deadline
            ?? (DispatchTime.now() + boundedCommandWallTimeLimit)
        guard let directSnapshot = boundedFileSnapshot(
            repository: repository,
            deadline: effectiveDeadline
        ) else {
            return true
        }
        if directSnapshot.currentCommit != nil,
           directSnapshot.branchName != ".invalid" {
            switch quickReferenceStorageName(repository: repository, deadline: effectiveDeadline) {
            case .complete(let storage):
                return storage.map { $0 != "files" } ?? false
            case .incomplete:
                let storage = referenceStorageName(
                    repository: repository,
                    branchContext: .resolved(directSnapshot.branchName),
                    deadline: effectiveDeadline
                )
                return storage.map { $0 != "files" } ?? false
            }
        }
        switch quickReferenceStorageName(repository: repository, deadline: effectiveDeadline) {
        case .complete(let storage):
            if let storage {
                return storage != "files"
                    || fileSnapshotRequiresPlumbing(repository: repository, deadline: effectiveDeadline)
            }
            return fileSnapshotRequiresPlumbing(repository: repository, deadline: effectiveDeadline)
        case .incomplete:
            // Includes and oversized configs may hide a non-files backend;
            // conservatively reserve a plumbing permit before the full scan.
            return true
        }
    }

    private func hasReftableDirectory(
        repository: ResolvedGitRepository,
        deadline: DispatchTime?
    ) -> Bool {
        let effectiveDeadline = deadline
            ?? (DispatchTime.now() + boundedCommandWallTimeLimit)
        [repository.gitDirectory, repository.commonDirectory].contains { directory in
            guard effectiveDeadline > DispatchTime.now() else { return false }
            let reftableDirectory = URL(fileURLWithPath: directory)
                .appendingPathComponent("reftable", isDirectory: true)
            guard storageProbe.isDirectory(atPath: reftableDirectory.path) else {
                return false
            }
            let marker = reftableDirectory.appendingPathComponent("tables.list")
            switch configReader.read(
                at: marker,
                maximumByteCount: 1,
                deadline: effectiveDeadline
            ) {
            case .contents, .oversized:
                return true
            case .missing, .unavailable:
                return false
            }
        }
    }

    /// Builds a snapshot from Git's storage-independent plumbing commands.
    private func plumbingSnapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime? = nil,
        includeStorageWatchPaths: Bool = false
    ) -> GitReferenceSnapshot {
        let deadline = deadline ?? (DispatchTime.now() + boundedCommandWallTimeLimit)
        guard let runner = runnerSelector.select(repository: repository, deadline: deadline) else {
            return unreadableSnapshot(usesGitPlumbing: true)
        }
        return plumbingSnapshot(
            repository: repository,
            runner: runner,
            deadline: deadline,
            includeStorageWatchPaths: includeStorageWatchPaths
        )
    }

    private func plumbingSnapshot(
        repository: ResolvedGitRepository,
        runner: any WorkspaceChangesGitRunning,
        deadline: DispatchTime,
        includeStorageWatchPaths: Bool
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
                currentCommit: nil,
                usesGitPlumbing: true
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
                    currentCommit: nil,
                    usesGitPlumbing: true
                )
            }
            return GitReferenceSnapshot(
                checkedOutBranch: .branch(branch),
                headSignature: "ref: \(stableReference.symbolicReference)\n\(stableReference.currentCommit ?? "")",
                currentCommit: stableReference.currentCommit,
                storageWatchPaths: includeStorageWatchPaths
                    ? storageWatchPaths(
                        repository: repository,
                        runner: runner,
                        symbolicReference: stableReference.symbolicReference,
                        deadline: deadline
                    )
                    : [],
                usesGitPlumbing: true
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
            storageWatchPaths: includeStorageWatchPaths
                ? storageWatchPaths(
                    repository: repository,
                    runner: runner,
                    symbolicReference: symbolicReference,
                    deadline: deadline
                )
                : [],
            usesGitPlumbing: true
        )
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

}
