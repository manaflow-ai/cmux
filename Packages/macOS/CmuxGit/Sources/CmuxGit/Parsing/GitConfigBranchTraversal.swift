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

    /// Creates a traversal for one repository and resolved branch context.
    init(
        repository: ResolvedGitRepository,
        branchContext: GitConfigBranchContext,
        configReader: GitConfigFileReader = GitConfigFileReader()
    ) {
        self.repository = repository
        self.branchContext = branchContext
        self.configReader = configReader
    }

    /// Returns every reachable config file in Git's include order.
    func configURLs() -> [URL] {
        traverse().configURLs
    }

    /// Returns bounded config paths to watch.
    func watchPaths() -> [String] {
        let result = traverse()
        var paths = result.configURLs.map { $0.standardizedFileURL.path }
        paths.append(contentsOf: result.referenceStoragePaths)
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    /// Returns the configured reference backend discovered during one bounded pass.
    func referenceStorageName() -> String? {
        let result = traverse()
        if result.referenceStorageName == nil, result.encounteredOversizedFile {
            return "unknown"
        }
        return result.referenceStorageName
    }

    private func traverse() -> (
        configURLs: [URL],
        referenceStorageName: String?,
        referenceStoragePaths: [String],
        encounteredOversizedFile: Bool
    ) {
        var urls: [URL] = []
        var storageName: String?
        var storagePaths: [String] = []
        var pendingURLs = GitMetadataService.gitRootConfigURLs(repository: repository)
        var seenConfigPaths: Set<String> = []
        var budget = GitConfigTraversalBudget(
            remainingPathCount: Self.maximumIncludedFileCount,
            remainingFileCount: Self.maximumIncludedFileCount,
            remainingByteCount: Self.maximumTotalConfigByteCount,
            reader: configReader
        )
        var encounteredOversizedFile = false

        while !pendingURLs.isEmpty {
            let configURL = pendingURLs.removeFirst().standardizedFileURL
            guard seenConfigPaths.insert(configURL.path).inserted else { continue }
            guard budget.reservePath() else { break }
            urls.append(configURL)
            guard let config = budget.read(at: configURL) else {
                encounteredOversizedFile = encounteredOversizedFile || budget.didEncounterOversizedFile
                continue
            }
            let storage = referenceStorageInfo(fromConfig: config, configURL: configURL)
            storageName = storage.name ?? storageName
            storagePaths.append(contentsOf: storage.paths)
            pendingURLs.append(contentsOf: includedConfigURLs(
                fromConfig: config,
                configURL: configURL,
                maximumCount: budget.remainingPathCount
            ))
        }
        return (urls, storageName, storagePaths, encounteredOversizedFile || budget.didEncounterOversizedFile)
    }

    private func referenceStorageInfo(
        fromConfig config: String,
        configURL: URL
    ) -> (name: String?, paths: [String]) {
        var name: String?
        var paths: [String] = []
        var inExtensionsSection = false
        for rawLine in config.components(separatedBy: .newlines) {
            let line = GitMetadataService.gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inExtensionsSection = line.lowercased() == "[extensions]"
                continue
            }
            guard inExtensionsSection else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0].lowercased() == "refstorage" else { continue }
            let value = GitMetadataService.gitConfigUnquotedValue(parts[1])
            let lowercasedValue = value.lowercased()
            guard let separator = lowercasedValue.firstIndex(of: ":") else {
                name = lowercasedValue
                continue
            }
            name = String(lowercasedValue[..<separator])
            var payload = String(value[value.index(after: separator)...])
            while payload.hasPrefix("/") && !payload.hasPrefix("//") {
                payload.removeFirst()
            }
            if payload.hasPrefix("//") {
                payload = String(payload.drop(while: { $0 == "/" }))
                payload = "/" + payload
            }
            guard !payload.isEmpty else { continue }
            let path = if payload.hasPrefix("/") {
                URL(fileURLWithPath: payload).standardizedFileURL.path
            } else {
                URL(fileURLWithPath: repository.commonDirectory)
                    .appendingPathComponent(payload)
                    .standardizedFileURL.path
            }
            if isSafeReferenceStoragePath(path) {
                paths.append(path)
            }
        }
        return (name, paths)
    }

    private func isSafeReferenceStoragePath(_ path: String) -> Bool {
        guard path != "/" else { return false }
        let roots = [repository.gitDirectory, repository.commonDirectory, repository.workTreeRoot]
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        return roots.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// Synthesizes `git remote -v` fetch lines from reachable config files.
    func remoteVOutput() -> String? {
        var lines: [String] = []
        var seenConfigPaths: Set<String> = []
        var budget = GitConfigTraversalBudget(
            remainingPathCount: Self.maximumIncludedFileCount,
            remainingFileCount: Self.maximumIncludedFileCount,
            remainingByteCount: Self.maximumTotalConfigByteCount,
            reader: configReader
        )
        for configURL in GitMetadataService.gitRootConfigURLs(repository: repository) {
            appendRemoteVLines(
                fromConfigURL: configURL,
                seenConfigPaths: &seenConfigPaths,
                lines: &lines,
                budget: &budget
            )
        }
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

    private func includedConfigURLs(
        fromConfig config: String,
        configURL: URL,
        maximumCount: Int
    ) -> [URL] {
        var urls: [URL] = []
        var currentSectionAllowsPath = false
        for rawLine in config.components(separatedBy: .newlines) {
            let line = GitMetadataService.gitConfigLineRemovingInlineComment(rawLine)
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentSectionAllowsPath = includeCondition(
                    fromSectionHeader: line,
                    configURL: configURL
                )
                continue
            }
            guard currentSectionAllowsPath else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2,
                  parts[0].lowercased() == "path",
                  let includeURL = GitMetadataService.gitConfigIncludeURL(
                      fromPathValue: parts[1],
                      relativeTo: configURL
                  ) else {
                continue
            }
            guard urls.count < maximumCount else { break }
            urls.append(includeURL)
        }
        return urls
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
