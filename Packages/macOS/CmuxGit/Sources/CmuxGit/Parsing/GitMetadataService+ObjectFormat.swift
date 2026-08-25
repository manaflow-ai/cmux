import Foundation

extension GitMetadataService {
    /// Detects SHA-256 object-format repositories before parsing a SHA-1 index.
    nonisolated func repositoryUsesSHA256ObjectIDs(
        repository: ResolvedGitRepository
    ) -> Bool {
        let reader = GitConfigFileReader()
        for configURL in Self.gitRootConfigURLs(repository: repository) {
            guard case .contents(let contents, consumedByteCount: _) = reader.read(
                at: configURL,
                maximumByteCount: GitConfigFileReader.defaultMaximumByteCount
            ) else { continue }
            var inExtensionsSection = false
            for rawLine in contents.split(whereSeparator: \.isNewline) {
                let line = Self.gitConfigLineRemovingInlineComment(String(rawLine))
                    .trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    inExtensionsSection = line.lowercased() == "[extensions]"
                    continue
                }
                guard inExtensionsSection else { continue }
                let parts = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.count == 2, parts[0].lowercased() == "objectformat" else { continue }
                return Self.gitConfigUnquotedValue(parts[1]).lowercased() == "sha256"
            }
        }
        return false
    }
}
