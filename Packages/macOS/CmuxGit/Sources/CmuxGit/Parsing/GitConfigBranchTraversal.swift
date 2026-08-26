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
        let paths: [String]
        let isComplete: Bool
        let objectFormatSHA256: Bool?
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
        var paths = result.configURLs.map { $0.standardizedFileURL.path }
        let worktreeConfigURL = URL(fileURLWithPath: repository.gitDirectory)
            .appendingPathComponent("config.worktree")
            .standardizedFileURL
        var rootWatchPaths = result.configURLs
            .prefix(2)
            .map { $0.standardizedFileURL.path }
        if result.isComplete, result.worktreeConfigEnabled {
            if result.configURLs.contains(where: { $0.standardizedFileURL == worktreeConfigURL }) {
                rootWatchPaths.append(worktreeConfigURL.path)
            } else {
                rootWatchPaths.append(worktreeConfigURL.deletingLastPathComponent().path)
            }
        }
        if !result.isComplete {
            // The caller promotes the repository root to a conservative,
            // throttled watcher when this bounded walk is incomplete.
            paths = rootWatchPaths + paths
        } else {
            // Keep a parent sentinel when extensions.worktreeConfig is enabled
            // but config.worktree has not been created yet.
            paths.append(contentsOf: rootWatchPaths)
        }
        paths.append(contentsOf: result.referenceStoragePaths)
        var seen: Set<String> = []
        return WatchPathResult(
            paths: Array(
                paths.filter { seen.insert($0).inserted }
                    .prefix(Self.maximumIncludedFileCount)
            ),
            isComplete: result.isComplete,
            objectFormatSHA256: result.isComplete ? result.objectFormatSHA256 : nil
        )
    }

    /// Returns the configured reference backend discovered during one bounded pass.
    func referenceStorageName() -> String? {
        let result = traverse()
        if !result.isComplete {
            return "unknown"
        }
        return result.referenceStorageName
    }

    private func traverse() -> (
        configURLs: [URL],
        referenceStorageName: String?,
        referenceStoragePaths: [String],
        encounteredOversizedFile: Bool,
        worktreeConfigEnabled: Bool,
        objectFormatSHA256: Bool?,
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
            state.referenceStoragePaths,
            state.budget.didEncounterOversizedFile,
            state.worktreeConfigEnabled,
            isComplete ? state.objectFormatSHA256 : nil,
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
            guard state.budget.canReservePath() else { return }
            if includeConditionalPathsForWatch,
               !isSafeConfigWatchPath(includeURL) {
                state.didEncounterUnsafeInclude = true
                continue
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
        let storageName = String(value[..<separator]).lowercased()
        // Preserve the path-qualified form for backend selection while using
        // the separately normalized name for path handling below.
        state.referenceStorageName = value.lowercased()
        var payload = String(value[value.index(after: separator)...])
        if payload.hasPrefix("//") {
            payload.removeFirst(2)
        }
        guard !payload.isEmpty else { return }
        let path = if payload.hasPrefix("/") {
            URL(fileURLWithPath: payload).standardizedFileURL.path
        } else {
            URL(fileURLWithPath: repository.gitDirectory)
                .appendingPathComponent(payload)
                .standardizedFileURL.path
        }
        if isSafeReferenceStoragePath(
            path,
            storageName: storageName
        ) {
            let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            if roots.contains(where: { root in
                path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }) {
                state.referenceStoragePaths.append(path)
            } else {
                let externalRoot = URL(fileURLWithPath: path)
                if storageName == "reftable" {
                    appendExternalWatchPath(
                        externalRoot.appendingPathComponent("tables.list"),
                        state: &state
                    )
                } else {
                    appendExternalFilesWatchPaths(
                        root: externalRoot,
                        state: &state
                    )
                }
            }
        }
    }

    private func isSafeReferenceStoragePath(_ path: String, storageName: String) -> Bool {
        guard path != "/" else { return false }
        let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let isInRepository = roots.contains(where: { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        })
        if isInRepository {
            return true
        }
        guard storageName == "reftable" || storageName == "files" else { return false }
        let rootURL = URL(fileURLWithPath: path)
        return configReader.isLocalDirectory(at: rootURL, deadline: deadline)
    }

    /// Adds a regular external marker or its bounded local parent sentinel.
    private func appendExternalWatchPath(
        _ targetURL: URL,
        state: inout GitConfigTraversalState,
        allowParentSentinel: Bool = true
    ) {
        let target = targetURL.standardizedFileURL
        if configReader.isLocalRegularFile(at: target, deadline: deadline) {
            state.referenceStoragePaths.append(target.path)
            return
        }
        guard allowParentSentinel else { return }
        let parent = target.deletingLastPathComponent()
        guard configReader.isLocalDirectory(at: parent, deadline: deadline) else { return }
        state.referenceStoragePaths.append(parent.path)
    }

    /// Watches only the current loose branch ref plus packed-refs for an
    /// external files store; never recursively watches the arbitrary store root.
    private func appendExternalFilesWatchPaths(
        root: URL,
        state: inout GitConfigTraversalState
    ) {
        if let branch = branchContext.branchName(for: repository, deadline: deadline) {
            let refRoot = root.appendingPathComponent("refs", isDirectory: true)
            let branchRef = refRoot
                .appendingPathComponent("heads", isDirectory: true)
                .appendingPathComponent(branch, isDirectory: false)
                .standardizedFileURL
            let refRootPath = refRoot.standardizedFileURL.path
            if branchRef.path.hasPrefix(refRootPath + "/") {
                appendExternalWatchPath(branchRef, state: &state)
            }
        }
        appendExternalWatchPath(
            root.appendingPathComponent("packed-refs", isDirectory: false),
            state: &state,
            allowParentSentinel: false
        )
    }

    /// Limits watch-mode include discovery to existing repository-local files.
    private func isSafeConfigWatchPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard roots.contains(where: { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) else {
            switch configReader.read(at: url, maximumByteCount: 1, deadline: deadline) {
            case .contents, .oversized:
                return true
            case .missing, .unavailable:
                return false
            }
        }
        switch configReader.read(at: url, maximumByteCount: 1, deadline: deadline) {
        case .contents, .oversized:
            return true
        case .missing, .unavailable:
            return false
        }
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
