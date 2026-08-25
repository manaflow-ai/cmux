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

    /// Creates a traversal for one repository and resolved branch context.
    init(
        repository: ResolvedGitRepository,
        branchContext: GitConfigBranchContext,
        configReader: GitConfigFileReader = GitConfigFileReader(),
        maximumFileByteCount: Int = GitConfigFileReader.defaultMaximumByteCount,
        storageProbe: any GitReferenceStorageProbing = SystemGitReferenceStorageProbe(),
        includeConditionalPathsForWatch: Bool = false
    ) {
        self.repository = repository
        self.branchContext = branchContext
        self.configReader = configReader
        self.maximumFileByteCount = max(0, maximumFileByteCount)
        self.storageProbe = storageProbe
        self.includeConditionalPathsForWatch = includeConditionalPathsForWatch
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
        guard state.seenConfigPaths.insert(configURL.path).inserted else { return }
        state.configURLs.append(configURL)
        guard state.budget.reservePath() else { return }
        guard let config = state.budget.read(at: configURL) else { return }

        var inExtensionsSection = false
        var currentSectionAllowsIncludePath = false
        for rawLine in config.components(separatedBy: .newlines) {
            let line = GitMetadataService.gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inExtensionsSection = line.lowercased() == "[extensions]"
                currentSectionAllowsIncludePath = includeConditionalPathsForWatch
                    && line.lowercased().hasPrefix("[includeif ")
                    || includeCondition(fromSectionHeader: line, configURL: configURL)
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
            if currentSectionAllowsIncludePath,
               parts.count == 2,
               parts[0].lowercased() == "path",
               let includeURL = GitMetadataService.gitConfigIncludeURL(
                   fromPathValue: parts[1],
                   relativeTo: configURL
               ),
               (!includeConditionalPathsForWatch || isSafeConfigWatchPath(includeURL)) {
                processConfig(at: includeURL, state: &state)
            }
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
            storageName: String(value[..<separator]).lowercased()
        ) {
            let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
                .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            if roots.contains(where: { root in
                path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }) {
                state.referenceStoragePaths.append(path)
            } else {
                let externalRoot = URL(fileURLWithPath: path)
                if String(value[..<separator]).lowercased() == "reftable" {
                    state.referenceStoragePaths.append(
                        externalRoot.appendingPathComponent("tables.list").path
                    )
                } else {
                    state.referenceStoragePaths.append(externalRoot.appendingPathComponent("refs").path)
                    state.referenceStoragePaths.append(externalRoot.appendingPathComponent("packed-refs").path)
                }
            }
        }
    }

    private func isSafeReferenceStoragePath(_ path: String, storageName: String) -> Bool {
        guard path != "/" else { return false }
        let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if roots.contains(where: { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) {
            return true
        }
        if storageName == "reftable" {
            let tableList = URL(fileURLWithPath: path).appendingPathComponent("tables.list")
            switch configReader.read(at: tableList, maximumByteCount: 1 * 1_024) {
            case .contents, .oversized:
                return true
            case .missing, .unavailable:
                return false
            }
        }
        let refsPath = URL(fileURLWithPath: path).appendingPathComponent("refs").path
        return storageProbe.isDirectory(atPath: refsPath)
            || configReader.read(
                at: URL(fileURLWithPath: path).appendingPathComponent("packed-refs"),
                maximumByteCount: 1
            ).isAvailable
    }

    /// Limits watch-mode include discovery to existing repository-local files.
    private func isSafeConfigWatchPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard roots.contains(where: { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }) else { return false }
        switch configReader.read(at: url, maximumByteCount: 1) {
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
        return GitConfigRemoteTraversalResult(
            output: lines.isEmpty ? nil : lines.joined(),
            isComplete: !budget.didExhaustBudget
        )
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
