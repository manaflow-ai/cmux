import Dispatch
import Foundation

/// Traverses repository config with a reference snapshot supplied by the owner.
///
/// The legacy static parsing entry points remain available for file-backed test
/// fixtures. This instance owns the resolved branch context used by production
/// reftable reads, so `includeIf.onbranch` never consults the sentinel `HEAD`.
nonisolated struct GitConfigBranchTraversal: Sendable {
    private static let maximumIncludedFileCount = 256
    private static let maximumTotalConfigByteCount = 8 * 1_024 * 1_024

    private let repository: ResolvedGitRepository
    private let branchContext: GitConfigBranchContext
    private let configReader: GitConfigFileReader
    private let maximumFileByteCount: Int
    private let storageProbe: any GitReferenceStorageProbing
    private let includeConditionalPathsForWatch: Bool
    private let deadline: DispatchTime?

    /// The bounded config roots and whether every reachable include was seen.
    struct WatchPathResult: Sendable {
        /// All paths currently needed by the filesystem watcher.
        let paths: [String]
        /// Paths whose descendants can change Git metadata and trigger a plan rebuild.
        let metadataPaths: [String]
        /// Existing parent roots watched only to observe creation of a missing file.
        let watchOnlyPaths: [String]
        let isComplete: Bool
        let objectFormatSHA256: Bool?
        let metadataSentinelPaths: [String]
    }

    /// Creates a traversal for one repository and resolved branch context.
    init(
        repository: ResolvedGitRepository,
        branchContext: GitConfigBranchContext,
        configReader: GitConfigFileReader = GitConfigFileReader(),
        maximumFileByteCount: Int = GitConfigFileReader.defaultMaximumByteCount,
        storageProbe: any GitReferenceStorageProbing = SystemGitReferenceStorageProbe(),
        includeConditionalPathsForWatch: Bool = false,
        deadline: DispatchTime? = nil
    ) {
        self.repository = repository
        self.branchContext = branchContext
        self.configReader = configReader
        self.maximumFileByteCount = max(0, maximumFileByteCount)
        self.storageProbe = storageProbe
        self.includeConditionalPathsForWatch = includeConditionalPathsForWatch
        self.deadline = deadline
    }

    /// Returns every reachable config file in Git's include order.
    func configURLs() -> [URL] {
        traverse().configURLs
    }

    /// Returns bounded config paths to watch.
    func watchPaths() -> [String] {
        watchPathResult().paths
    }

    /// Returns bounded config paths plus completion state for watcher planning.
    func watchPathResult() -> WatchPathResult {
        let result = traverse()
        let worktreeConfigURL = URL(fileURLWithPath: repository.gitDirectory)
            .appendingPathComponent("config.worktree")
            .standardizedFileURL
        var rootWatchPaths = result.configURLs
            .prefix(2)
            .map { $0.standardizedFileURL.path }
        var worktreeConfigIsMissing = false
        if result.worktreeConfigEnabled || !result.isComplete {
            if configReader.isLocalRegularFile(at: worktreeConfigURL, deadline: deadline) {
                rootWatchPaths.append(worktreeConfigURL.path)
            } else {
                rootWatchPaths.append(worktreeConfigURL.deletingLastPathComponent().path)
                worktreeConfigIsMissing = result.worktreeConfigEnabled
            }
        }
        let deferredPaths = Array(Set(result.deferredConfigPaths)).sorted()
        let missingPaths = Array(Set(result.missingConfigPaths)).sorted()
        let mandatorySentinelPaths = worktreeConfigIsMissing ? [worktreeConfigURL.path] : []
        let availableSentinelCount = max(
            0,
            Self.maximumIncludedFileCount - mandatorySentinelPaths.count
        )
        let deferredSentinelPaths = Array(deferredPaths.prefix(availableSentinelCount))
        let missingSentinelCount = max(0, availableSentinelCount - deferredSentinelPaths.count)
        let metadataSentinelPaths = deferredSentinelPaths
            + Array(missingPaths.prefix(missingSentinelCount))
            + mandatorySentinelPaths
        let metadataSentinelParentPaths = Array(
            Set(result.missingConfigParentPaths + result.deferredConfigParentPaths)
                .sorted()
                .prefix(Self.maximumIncludedFileCount)
        )
        // Keep the mandatory repository config roots ahead of optional include
        // sentinels so the bounded path list can never evict them. Parent
        // directories are watcher roots only; they must not become metadata
        // overlap paths or every unrelated child event will rebuild the plan.
        let watchOnlyCandidates = rootWatchPaths.filter { rootWatchPath in
            metadataSentinelParentPaths.contains(rootWatchPath)
        } + (worktreeConfigIsMissing
            ? [worktreeConfigURL.deletingLastPathComponent().path]
            : []) + Array(metadataSentinelParentPaths)
        let metadataCandidates = result.configURLs.map { $0.standardizedFileURL.path }
            + referenceStorageWatchPaths(for: result.referenceStorageName)
            + deferredSentinelPaths
        let paths = rootWatchPaths
            + Array(metadataSentinelParentPaths)
            + metadataCandidates
        // For an incomplete walk the caller adds its conservative root safety
        // valve; complete walks retain only these bounded exact paths.
        var seen: Set<String> = []
        let boundedPaths = Array(
            paths.filter { seen.insert($0).inserted }
                .prefix(Self.maximumIncludedFileCount)
        )
        let watchOnlySet = Set(watchOnlyCandidates)
        return WatchPathResult(
            paths: boundedPaths,
            metadataPaths: boundedPaths.filter { !watchOnlySet.contains($0) },
            watchOnlyPaths: boundedPaths.filter { watchOnlySet.contains($0) },
            isComplete: result.isComplete,
            objectFormatSHA256: result.isComplete ? result.objectFormatSHA256 : nil,
            metadataSentinelPaths: Array(metadataSentinelPaths)
        )
    }

    /// Returns the configured reference backend discovered during one bounded pass.
    func referenceStorageName() -> String? {
        let result = traverse()
        guard !result.isComplete else { return result.referenceStorageName }
        // A partial walk must not trust a `files` value because a later
        // include may override it. A discovered non-files backend is safe to
        // treat conservatively as plumbing, however, and preserves external
        // storage paths that Git reports for watcher setup.
        guard let storage = result.referenceStorageName else { return "unknown" }
        let backend: String
        if let separator = storage.firstIndex(of: ":") {
            backend = String(storage[..<separator]).lowercased()
        } else {
            backend = storage.lowercased()
        }
        return backend == "files" ? "unknown" : storage
    }

    private func traverse() -> (
        configURLs: [URL],
        referenceStorageName: String?,
        encounteredOversizedFile: Bool,
        worktreeConfigEnabled: Bool,
        objectFormatSHA256: Bool?,
        missingConfigPaths: [String],
        missingConfigParentPaths: [String],
        deferredConfigPaths: [String],
        deferredConfigParentPaths: [String],
        isComplete: Bool
    ) {
        var state = GitConfigTraversalState(budget: GitConfigTraversalBudget(
            remainingPathCount: Self.maximumIncludedFileCount,
            remainingFileCount: Self.maximumIncludedFileCount,
            remainingByteCount: Self.maximumTotalConfigByteCount,
            reader: configReader,
            maximumFileByteCount: maximumFileByteCount,
            deadline: deadline
        ))
        let rootConfigURLs = [
            URL(fileURLWithPath: repository.commonDirectory).appendingPathComponent("config"),
            URL(fileURLWithPath: repository.gitDirectory).appendingPathComponent("config"),
        ]
        for configURL in rootConfigURLs {
            processConfig(at: configURL, state: &state)
        }
        if state.worktreeConfigEnabled {
            processConfig(
                at: URL(fileURLWithPath: repository.gitDirectory)
                    .appendingPathComponent("config.worktree"),
                state: &state
            )
        }
        let isComplete = !state.budget.didExhaustBudget
            && !state.didEncounterUnsafeInclude
        return (
            state.configURLs,
            state.referenceStorageName,
            state.budget.didEncounterOversizedFile,
            state.worktreeConfigEnabled,
            isComplete ? state.objectFormatSHA256 : nil,
            state.missingConfigPaths,
            state.missingConfigParentPaths,
            state.deferredConfigPaths,
            state.deferredConfigParentPaths,
            isComplete
        )
    }

    private func processConfig(
        at rawURL: URL,
        state: inout GitConfigTraversalState
    ) {
        let configURL = rawURL.standardizedFileURL
        guard !state.seenConfigPaths.contains(configURL.path),
              state.budget.reservePath() else { return }
        state.seenConfigPaths.insert(configURL.path)
        state.configURLs.append(configURL)
        guard let config = state.budget.read(at: configURL) else { return }

        var inExtensionsSection = false
        var currentSectionAllowsIncludePath = false
        for rawLine in config.components(separatedBy: .newlines) {
            if state.budget.isExpired {
                state.budget.didExhaustBudget = true
                return
            }
            let line = GitMetadataService.gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inExtensionsSection = line.lowercased() == "[extensions]"
                currentSectionAllowsIncludePath = includeCondition(
                    fromSectionHeader: line,
                    configURL: configURL
                )
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if inExtensionsSection,
               parts.count == 2,
               parts[0].lowercased() == "refstorage" {
                recordReferenceStorage(
                    GitMetadataService.gitConfigUnquotedValue(parts[1]),
                    state: &state
                )
            }
            if inExtensionsSection, !parts.isEmpty {
                let key = parts[0].lowercased()
                let value = parts.count == 1
                    ? "true"
                    : GitMetadataService.gitConfigUnquotedValue(parts[1]).lowercased()
                if key == "worktreeconfig" {
                    state.worktreeConfigEnabled = ["true", "yes", "on", "1", "t", "y"].contains(value)
                } else if key == "objectformat", parts.count == 2 {
                    state.objectFormatSHA256 = value == "sha256"
                }
            }
            guard currentSectionAllowsIncludePath,
                  parts.count == 2,
                  parts[0].lowercased() == "path",
                  let includeURL = GitMetadataService.gitConfigIncludeURL(
                      fromPathValue: parts[1],
                      relativeTo: configURL
                  ) else {
                continue
            }
            guard !state.seenConfigPaths.contains(includeURL.standardizedFileURL.path) else {
                continue
            }
            guard state.budget.canReservePath() else {
                if includeConditionalPathsForWatch {
                    state.recordDeferredIncludePath(includeURL, repository: repository)
                }
                return
            }
            if includeConditionalPathsForWatch {
                switch configReader.read(at: includeURL, maximumByteCount: 1, deadline: deadline) {
                case .contents, .oversized:
                    break
                case .missing:
                    guard state.budget.reservePath() else { return }
                    if let parent = state.existingRepositoryConfigParent(
                        for: includeURL,
                        repository: repository,
                        configReader: configReader,
                        deadline: deadline
                    ) {
                        state.missingConfigPaths.append(includeURL.standardizedFileURL.path)
                        state.missingConfigParentPaths.append(parent)
                    } else {
                        state.didEncounterUnsafeInclude = true
                    }
                    continue
                case .unavailable:
                    guard state.budget.reservePath() else { return }
                    state.didEncounterUnsafeInclude = true
                    continue
                }
            }
            processConfig(at: includeURL, state: &state)
        }
    }

    private func recordReferenceStorage(
        _ value: String,
        state: inout GitConfigTraversalState
    ) {
        guard let separator = value.firstIndex(of: ":") else {
            state.referenceStorageName = value.lowercased()
            return
        }
        // Normalize only the backend name. Preserve the path's original case
        // because external files reference stores can be case-sensitive.
        let storageName = String(value[..<separator]).lowercased()
        state.referenceStorageName = storageName + String(value[separator...])
    }

    /// Computes bounded watcher paths for the final effective ref-storage
    /// directive. Git applies repeated directives in order, so planning only
    /// the last value keeps repository-controlled config scans bounded.
    private func referenceStorageWatchPaths(for value: String?) -> [String] {
        guard includeConditionalPathsForWatch,
              let value,
              let separator = value.firstIndex(of: ":") else {
            return []
        }
        let storageName = String(value[..<separator]).lowercased()
        var payload = String(value[value.index(after: separator)...])
        if payload.hasPrefix("//") {
            payload.removeFirst(2)
        }
        guard !payload.isEmpty else { return [] }
        let path = if payload.hasPrefix("/") {
            URL(fileURLWithPath: payload).standardizedFileURL.path
        } else {
            URL(fileURLWithPath: repository.gitDirectory)
                .appendingPathComponent(payload)
                .standardizedFileURL.path
        }
        let planner = GitConfigReferenceStorageWatchPlanner(
            repository: repository,
            branchContext: branchContext,
            configReader: configReader,
            deadline: deadline
        )
        return planner.watchPaths(
            storageName: storageName,
            path: path
        )
    }

    /// Synthesizes `git remote -v` fetch lines from reachable config files.
    func remoteVOutput() -> String? {
        remoteVResult().output
    }

    /// Synthesizes remote lines while preserving whether the bounded walk completed.
    func remoteVResult() -> GitConfigRemoteTraversalResult {
        var lines: [String] = []
        var seenConfigPaths: Set<String> = []
        var budget = GitConfigTraversalBudget(
            remainingPathCount: Self.maximumIncludedFileCount,
            remainingFileCount: Self.maximumIncludedFileCount,
            remainingByteCount: Self.maximumTotalConfigByteCount,
            reader: configReader,
            maximumFileByteCount: maximumFileByteCount,
            deadline: deadline
        )
        for configURL in GitWorktreeConfigEnablementReader().rootConfigURLs(
            repository: repository,
            deadline: deadline,
            branchContext: branchContext
        ) {
            appendRemoteVLines(
                fromConfigURL: configURL,
                seenConfigPaths: &seenConfigPaths,
                lines: &lines,
                budget: &budget
            )
        }
        return GitConfigRemoteTraversalResult(
            output: lines.isEmpty ? nil : lines.joined(),
            isComplete: !budget.didExhaustBudget,
            isUnsafe: budget.didEncounterUnsafeFile
        )
    }

    private func appendRemoteVLines(
        fromConfigURL rawConfigURL: URL,
        seenConfigPaths: inout Set<String>,
        lines: inout [String],
        budget: inout GitConfigTraversalBudget
    ) {
        let configURL = rawConfigURL.standardizedFileURL
        guard !seenConfigPaths.contains(configURL.path),
              budget.reservePath() else {
            return
        }
        seenConfigPaths.insert(configURL.path)
        guard let config = budget.read(at: configURL) else { return }

        var currentRemoteName: String?
        var currentSectionAllowsIncludePath = false
        for rawLine in config.components(separatedBy: .newlines) {
            if budget.isExpired {
                budget.didExhaustBudget = true
                return
            }
            let line = GitMetadataService.gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentRemoteName = GitMetadataService.gitConfigRemoteName(
                    fromSectionHeader: line
                )
                currentSectionAllowsIncludePath = includeCondition(
                    fromSectionHeader: line,
                    configURL: configURL
                )
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if let currentRemoteName,
               parts.count == 2,
               parts[0].lowercased() == "url" {
                let remoteURL = GitMetadataService.gitConfigUnquotedValue(parts[1])
                if !remoteURL.isEmpty {
                    lines.append("\(currentRemoteName)\t\(remoteURL) (fetch)\n")
                }
                continue
            }

            guard currentSectionAllowsIncludePath,
                  parts.count == 2,
                  parts[0].lowercased() == "path",
                  let includeURL = GitMetadataService.gitConfigIncludeURL(
                      fromPathValue: parts[1],
                      relativeTo: configURL
                  ) else {
                continue
            }
            guard !seenConfigPaths.contains(includeURL.standardizedFileURL.path) else {
                continue
            }
            guard budget.canReservePath() else { return }
            appendRemoteVLines(
                fromConfigURL: includeURL,
                seenConfigPaths: &seenConfigPaths,
                lines: &lines,
                budget: &budget
            )
        }
    }

    private func includeCondition(fromSectionHeader header: String, configURL: URL) -> Bool {
        if header.lowercased() == "[include]" {
            return true
        }
        guard let condition = GitMetadataService.gitConfigIncludeIfCondition(
            fromSectionHeader: header
        ) else {
            return false
        }
        return conditionMatches(condition, configURL: configURL)
    }

    private func conditionMatches(_ condition: String, configURL: URL) -> Bool {
        let lowercasedCondition = condition.lowercased()
        if lowercasedCondition.hasPrefix("gitdir/i:") {
            return GitMetadataService.gitConfigGitdirPatternMatches(
                String(condition.dropFirst("gitdir/i:".count)),
                repository: repository,
                caseInsensitive: true,
                configURL: configURL
            )
        }
        if lowercasedCondition.hasPrefix("gitdir:") {
            return GitMetadataService.gitConfigGitdirPatternMatches(
                String(condition.dropFirst("gitdir:".count)),
                repository: repository,
                caseInsensitive: false,
                configURL: configURL
            )
        }
        guard lowercasedCondition.hasPrefix("onbranch:") else { return false }
        var pattern = String(condition.dropFirst("onbranch:".count))
        if pattern.hasSuffix("/") {
            pattern.append("**")
        }
        guard let branch = branchContext.branchName(for: repository, deadline: deadline) else { return false }
        return GitMetadataService.gitConfigGlobMatches(
            branch,
            pattern: pattern,
            caseInsensitive: false
        )
    }
}
