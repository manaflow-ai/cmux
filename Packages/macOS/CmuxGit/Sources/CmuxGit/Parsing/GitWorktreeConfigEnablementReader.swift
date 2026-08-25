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
        repository _: ResolvedGitRepository,
        rootURLs: [URL]
    ) -> Bool {
        var pendingURLs = rootURLs
        var seenPaths: Set<String> = []
        var remainingPathCount = Self.maximumPathCount
        var remainingByteCount = Self.maximumByteCount
        var enabled = false

        while let rawURL = pendingURLs.first {
            pendingURLs.removeFirst()
            let configURL = rawURL.standardizedFileURL
            guard seenPaths.insert(configURL.path).inserted else { continue }
            guard remainingPathCount > 0, remainingByteCount > 0 else { return false }
            remainingPathCount -= 1
            let readLimit = min(remainingByteCount, GitConfigFileReader.defaultMaximumByteCount)
            switch reader.read(at: configURL, maximumByteCount: readLimit) {
            case .missing:
                continue
            case .oversized, .unavailable:
                return false
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
                        includeSection = lowercased == "[include]"
                            || lowercased.hasPrefix("[includeif ")
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
                    guard includeSection,
                          parts.count == 2,
                          parts[0].lowercased() == "path",
                          let includeURL = GitMetadataService.gitConfigIncludeURL(
                              fromPathValue: parts[1],
                              relativeTo: configURL
                          ) else {
                        continue
                    }
                    pendingURLs.append(includeURL)
                }
            }
        }
        return enabled
    }
}
