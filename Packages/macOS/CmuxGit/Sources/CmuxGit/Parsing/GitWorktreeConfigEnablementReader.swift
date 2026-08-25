import Foundation

/// Resolves `extensions.worktreeConfig` through a bounded config include walk.
nonisolated struct GitWorktreeConfigEnablementReader: Sendable {
    private static let maximumPathCount = 256
    private static let maximumByteCount = 8 * 1_024 * 1_024

    private let reader: GitConfigFileReader

    init(reader: GitConfigFileReader = GitConfigFileReader()) {
        self.reader = reader
    }

    func isEnabled(
        repository: ResolvedGitRepository,
        rootURLs: [URL]
    ) -> Bool {
        var seenPaths: Set<String> = []
        var remainingPathCount = Self.maximumPathCount
        var remainingByteCount = Self.maximumByteCount
        var enabled = false
        var objectFormatSHA256 = false
        var failed = false
        for rootURL in rootURLs {
            process(
                at: rootURL,
                repository: repository,
                seenPaths: &seenPaths,
                remainingPathCount: &remainingPathCount,
                remainingByteCount: &remainingByteCount,
                enabled: &enabled,
                objectFormatSHA256: &objectFormatSHA256,
                failed: &failed
            )
            if failed { return false }
        }
        return enabled
    }

    func isSHA256ObjectFormat(
        repository: ResolvedGitRepository,
        rootURLs: [URL]
    ) -> Bool {
        var seenPaths: Set<String> = []
        var remainingPathCount = Self.maximumPathCount
        var remainingByteCount = Self.maximumByteCount
        var enabled = false
        var objectFormatSHA256 = false
        var failed = false
        for rootURL in rootURLs {
            process(
                at: rootURL,
                repository: repository,
                seenPaths: &seenPaths,
                remainingPathCount: &remainingPathCount,
                remainingByteCount: &remainingByteCount,
                enabled: &enabled,
                objectFormatSHA256: &objectFormatSHA256,
                failed: &failed
            )
            if failed { return false }
        }
        return objectFormatSHA256
    }

    private func process(
        at rawURL: URL,
        repository: ResolvedGitRepository,
        seenPaths: inout Set<String>,
        remainingPathCount: inout Int,
        remainingByteCount: inout Int,
        enabled: inout Bool,
        objectFormatSHA256: inout Bool,
        failed: inout Bool
    ) {
        let configURL = rawURL.standardizedFileURL
        guard seenPaths.insert(configURL.path).inserted else { return }
        guard remainingPathCount > 0, remainingByteCount > 0 else {
            failed = true
            return
        }
        remainingPathCount -= 1
        let readLimit = min(remainingByteCount, GitConfigFileReader.defaultMaximumByteCount)
        switch reader.read(at: configURL, maximumByteCount: readLimit) {
        case .missing:
            return
        case .oversized, .unavailable:
            failed = true
            return
        case .contents(let contents, consumedByteCount: let consumedByteCount):
            remainingByteCount = max(0, remainingByteCount - consumedByteCount)
            var inExtensionsSection = false
            var includeSection = false
            for rawLine in contents.split(whereSeparator: \.isNewline) {
                let line = GitMetadataService.gitConfigLineRemovingInlineComment(String(rawLine))
                    .trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    let lowercased = line.lowercased()
                    inExtensionsSection = lowercased == "[extensions]"
                    if lowercased == "[include]" {
                        includeSection = true
                    } else if let condition = GitMetadataService.gitConfigIncludeIfCondition(
                        fromSectionHeader: line
                    ) {
                        includeSection = GitMetadataService.gitConfigIncludeIfConditionMatches(
                            condition,
                            repository: repository,
                            configURL: configURL
                        )
                    } else {
                        includeSection = false
                    }
                    continue
                }
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if inExtensionsSection,
                   !parts.isEmpty,
                   parts[0].lowercased() == "worktreeconfig" {
                    let value = parts.count == 1
                        ? "true"
                        : GitMetadataService.gitConfigUnquotedValue(parts[1]).lowercased()
                    enabled = ["true", "yes", "on", "1", "t", "y"].contains(value)
                }
                if inExtensionsSection,
                   parts.count == 2,
                   parts[0].lowercased() == "objectformat" {
                    objectFormatSHA256 = GitMetadataService.gitConfigUnquotedValue(parts[1])
                        .lowercased() == "sha256"
                }
                guard includeSection,
                      parts.count == 2,
                      parts[0].lowercased() == "path",
                      let includeURL = GitMetadataService.gitConfigIncludeURL(
                          fromPathValue: parts[1],
                          relativeTo: configURL
                      ) else {
                    continue
                }
                process(
                    at: includeURL,
                    repository: repository,
                    seenPaths: &seenPaths,
                    remainingPathCount: &remainingPathCount,
                    remainingByteCount: &remainingByteCount,
                    enabled: &enabled,
                    objectFormatSHA256: &objectFormatSHA256,
                    failed: &failed
                )
                if failed { return }
            }
        }
    }
}
