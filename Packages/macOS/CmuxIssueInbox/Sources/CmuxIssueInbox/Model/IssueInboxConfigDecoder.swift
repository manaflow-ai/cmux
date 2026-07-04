public import Foundation

/// Decodes Issue Inbox configuration with lossy source-entry handling.
public struct IssueInboxConfigDecoder: Sendable {
    private let homeDirectory: URL

    /// Creates a config decoder.
    ///
    /// - Parameter homeDirectory: Home directory used for tilde expansion.
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// Decodes config JSON while skipping malformed source entries.
    ///
    /// - Parameter data: Raw config JSON bytes.
    /// - Returns: Parsed configuration plus non-fatal warnings.
    /// - Throws: Top-level JSON decoding errors.
    public func decode(_ data: Data) throws -> (config: IssueInboxConfig, warnings: [IssueInboxConfigWarning]) {
        let raw = try JSONDecoder().decode(RawIssueInboxConfig.self, from: data)
        var warnings: [IssueInboxConfigWarning] = []
        var sources: [IssueInboxSourceConfig] = []
        for index in raw.discardedSourceIndexes {
            warnings.append(warning(index: index, message: "Issue source entry could not be decoded."))
        }
        for entry in raw.sources {
            switch sourceConfig(from: entry.source, index: entry.index) {
            case .success(let source):
                sources.append(source)
            case .failure(let warning):
                warnings.append(warning)
            }
        }
        if raw.autoRefreshSeconds != 0 {
            warnings.append(IssueInboxConfigWarning(
                id: "autoRefreshSeconds",
                message: "autoRefreshSeconds is parsed but only 0 is supported in V1."
            ))
        }
        return (
            IssueInboxConfig(
                sources: sources,
                autoRefreshSeconds: raw.autoRefreshSeconds
            ),
            warnings
        )
    }

    private func sourceConfig(
        from entry: RawIssueInboxSource,
        index: Int
    ) -> SourceConfigDecodeResult {
        guard let type = IssueProviderKind(rawValue: entry.type.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failure(warning(index: index, message: "Unsupported issue source type '\(entry.type)'."))
        }

        let projectRoot = entry.projectRoot.flatMap { expandedProjectRoot($0) }
        switch type {
        case .github:
            guard let repo = nonEmpty(entry.repo) else {
                return .failure(warning(index: index, message: "GitHub issue source requires repo."))
            }
            return .success(IssueInboxSourceConfig(
                type: .github,
                repo: repo,
                projectRoot: projectRoot
            ))
        case .linear:
            guard let teamKey = nonEmpty(entry.teamKey) else {
                return .failure(warning(index: index, message: "Linear issue source requires teamKey."))
            }
            return .success(IssueInboxSourceConfig(
                type: .linear,
                teamKey: teamKey,
                projectRoot: projectRoot,
                apiKeyEnvVar: nonEmpty(entry.apiKeyEnvVar) ?? "LINEAR_API_KEY"
            ))
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func expandedProjectRoot(_ value: String) -> String? {
        guard let trimmed = nonEmpty(value) else { return nil }
        if trimmed == "~" {
            return homeDirectory.path
        }
        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            return homeDirectory.appendingPathComponent(suffix).standardizedFileURL.path
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func warning(index: Int, message: String) -> IssueInboxConfigWarning {
        IssueInboxConfigWarning(id: "sources.\(index)", message: message)
    }
}

private struct RawIssueInboxConfig: Decodable {
    var sources: [IndexedRawIssueInboxSource] = []
    var discardedSourceIndexes: [Int] = []
    var autoRefreshSeconds: Int = 0

    private enum CodingKeys: String, CodingKey {
        case sources
        case autoRefreshSeconds
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let sourceList = try container.decodeIfPresent(LossyIssueInboxSourceList.self, forKey: .sources) {
            sources = sourceList.values
            discardedSourceIndexes = sourceList.discardedIndexes
        }
        autoRefreshSeconds = try container.decodeIfPresent(Int.self, forKey: .autoRefreshSeconds) ?? 0
    }
}

private struct IndexedRawIssueInboxSource {
    var index: Int
    var source: RawIssueInboxSource
}

private struct LossyIssueInboxSourceList: Decodable {
    var values: [IndexedRawIssueInboxSource]
    var discardedIndexes: [Int]

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [IndexedRawIssueInboxSource] = []
        var discarded: [Int] = []
        var index = 0
        while !container.isAtEnd {
            if let source = try? container.decode(RawIssueInboxSource.self) {
                decoded.append(IndexedRawIssueInboxSource(index: index, source: source))
            } else {
                discarded.append(index)
                _ = try? container.decode(DiscardedIssueInboxSource.self)
            }
            index += 1
        }
        values = decoded
        discardedIndexes = discarded
    }
}

private struct RawIssueInboxSource: Decodable {
    var type: String
    var repo: String?
    var teamKey: String?
    var projectRoot: String?
    var apiKeyEnvVar: String?
}

private struct DiscardedIssueInboxSource: Decodable {}

private enum SourceConfigDecodeResult {
    case success(IssueInboxSourceConfig)
    case failure(IssueInboxConfigWarning)
}
