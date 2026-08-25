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

    /// Creates a traversal for one repository and resolved branch context.
    init(
        repository: ResolvedGitRepository,
        branchContext: GitConfigBranchContext,
        configReader: GitConfigFileReader = GitConfigFileReader(),
        maximumFileByteCount: Int = GitConfigFileReader.defaultMaximumByteCount
    ) {
        self.repository = repository
        self.branchContext = branchContext
        self.configReader = configReader
        self.maximumFileByteCount = max(0, maximumFileByteCount)
    }

    /// Returns every reachable config file in Git's include order.
    func configURLs() -> [URL] {
        traverse().configURLs
    }

    /// Returns bounded config paths to watch.
    func watchPaths() -> [String] {
        let result = traverse()
        var paths = result.configURLs.map { $0.standardizedFileURL.path }
        if !result.isComplete {
            paths.append(contentsOf: GitMetadataService.gitRootConfigURLs(repository: repository).map(\.path))
        }
        paths.append(contentsOf: result.referenceStoragePaths)
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
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
        isComplete: Bool
    ) {
        var state = GitConfigTraversalState(budget: GitConfigTraversalBudget(
            remainingPathCount: Self.maximumIncludedFileCount,
            remainingFileCount: Self.maximumIncludedFileCount,
            remainingByteCount: Self.maximumTotalConfigByteCount,
            reader: configReader,
            maximumFileByteCount: maximumFileByteCount
        ))
        for configURL in GitMetadataService.gitRootConfigURLs(repository: repository) {
            processConfig(at: configURL, state: &state)
        }
        return (
            state.configURLs,
            state.referenceStorageName,
            state.referenceStoragePaths,
            state.budget.didEncounterOversizedFile,
            !state.budget.didExhaustBudget
        )
    }

    private func processConfig(
        at rawURL: URL,
        state: inout GitConfigTraversalState
    ) {
        let configURL = rawURL.standardizedFileURL
        guard state.seenConfigPaths.insert(configURL.path).inserted,
              state.budget.reservePath() else { return }
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
                    configURL: configURL,
                    state: &state
                )
            }
            if currentSectionAllowsIncludePath,
               parts.count == 2,
               parts[0].lowercased() == "path",
               let includeURL = GitMetadataService.gitConfigIncludeURL(
                   fromPathValue: parts[1],
                   relativeTo: configURL
               ) {
                processConfig(at: includeURL, state: &state)
            }
        }
    }

    private func recordReferenceStorage(
        _ value: String,
        configURL: URL,
        state: inout GitConfigTraversalState
    ) {
        guard let separator = value.firstIndex(of: ":") else {
            state.referenceStorageName = value.lowercased()
            return
        }
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
        if isSafeReferenceStoragePath(path) {
            state.referenceStoragePaths.append(path)
        }
    }

    private func isSafeReferenceStoragePath(_ path: String) -> Bool {
        guard path != "/" else { return false }
        let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if roots.contains(where: { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) {
            return true
        }
        // External stores are accepted only when their concrete reftable marker
        // is an existing bounded regular file; broad roots such as `/` cannot
        // satisfy this check and are never handed to the recursive watcher.
        let tableList = URL(fileURLWithPath: path).appendingPathComponent("tables.list")
        if case .contents = configReader.read(at: tableList, maximumByteCount: 1 * 1_024) {
            return path.split(separator: "/").count >= 3
        }
        return false
    }

    /// Synthesizes `git remote -v` fetch lines from reachable config files.
    func remoteVOutput() -> String? {
        var lines: [String] = []
        var seenConfigPaths: Set<String> = []
        var budget = GitConfigTraversalBudget(
            remainingPathCount: Self.maximumIncludedFileCount,
            remainingFileCount: Self.maximumIncludedFileCount,
            remainingByteCount: Self.maximumTotalConfigByteCount,
            reader: configReader,
            maximumFileByteCount: maximumFileByteCount
        )
        for configURL in GitMetadataService.gitRootConfigURLs(repository: repository) {
            appendRemoteVLines(
                fromConfigURL: configURL,
                seenConfigPaths: &seenConfigPaths,
                lines: &lines,
                budget: &budget
            )
        }
        guard !budget.didExhaustBudget else { return nil }
        return lines.isEmpty ? nil : lines.joined()
    }

    private func appendRemoteVLines(
        fromConfigURL rawConfigURL: URL,
        seenConfigPaths: inout Set<String>,
        lines: inout [String],
        budget: inout GitConfigTraversalBudget
    ) {
        let configURL = rawConfigURL.standardizedFileURL
        guard seenConfigPaths.insert(configURL.path).inserted,
              budget.reservePath(),
              let config = budget.read(at: configURL) else {
            return
        }

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
        guard let branch = branchContext.branchName(for: repository) else { return false }
        return GitMetadataService.gitConfigGlobMatches(
            branch,
            pattern: pattern,
            caseInsensitive: false
        )
    }
}
