import Foundation

/// Derives normalized, de-duplicated search keywords for one switcher entry
/// from base keywords plus workspace/surface metadata.
///
/// A value object: construct it with the entry's base keywords and metadata,
/// then read `keywords` for the unique, order-preserving result.
public struct CommandPaletteSwitcherSearchIndexer: Sendable {
    /// How much metadata detail to tokenize: workspaces index whole paths,
    /// surfaces additionally index path/branch components.
    public enum MetadataDetail: Sendable {
        /// Workspace-level detail (whole values only).
        case workspace
        /// Surface-level detail (whole values plus components).
        case surface
    }

    private static let metadataDelimiters = CharacterSet(charactersIn: "/\\.:_- ")

    /// Base keywords supplied for the entry.
    public let baseKeywords: [String]
    /// Workspace/surface metadata to tokenize.
    public let metadata: CommandPaletteSwitcherSearchMetadata
    /// How much metadata detail to tokenize.
    public let detail: MetadataDetail

    /// Captures the inputs for one switcher entry's keyword derivation.
    public init(
        baseKeywords: [String],
        metadata: CommandPaletteSwitcherSearchMetadata,
        detail: MetadataDetail = .surface
    ) {
        self.baseKeywords = baseKeywords
        self.metadata = metadata
        self.detail = detail
    }

    /// The unique, order-preserving keyword list for the entry.
    public var keywords: [String] {
        let metadataKeywords = Self.metadataKeywordsForSearch(metadata, detail: detail)
        return Self.uniqueNormalizedPreservingOrder(baseKeywords + metadataKeywords)
    }

    private static func metadataKeywordsForSearch(
        _ metadata: CommandPaletteSwitcherSearchMetadata,
        detail: MetadataDetail
    ) -> [String] {
        let directoryTokens = metadata.directories.flatMap { directoryTokensForSearch($0, detail: detail) }
        let branchTokens = metadata.branches.flatMap { branchTokensForSearch($0, detail: detail) }
        let portTokens = metadata.ports.flatMap(portTokensForSearch)
        let descriptionTokens = descriptionTokensForSearch(metadata.description)

        var contextKeywords: [String] = []
        if !directoryTokens.isEmpty {
            contextKeywords.append(contentsOf: ["directory", "dir", "cwd", "path"])
        }
        if !branchTokens.isEmpty {
            contextKeywords.append(contentsOf: ["branch", "git"])
        }
        if !portTokens.isEmpty {
            contextKeywords.append(contentsOf: ["port", "ports"])
        }
        if !descriptionTokens.isEmpty {
            contextKeywords.append(contentsOf: ["description", "descriptions", "notes", "note"])
        }

        return contextKeywords + directoryTokens + branchTokens + portTokens + descriptionTokens
    }

    private static func directoryTokensForSearch(
        _ rawDirectory: String,
        detail: MetadataDetail
    ) -> [String] {
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let standardized = (trimmed as NSString).standardizingPath
        let canonical = standardized.isEmpty ? trimmed : standardized
        let abbreviated = (canonical as NSString).abbreviatingWithTildeInPath
        switch detail {
        case .workspace:
            return uniqueNormalizedPreservingOrder([trimmed, canonical, abbreviated])
        case .surface:
            let basename = URL(fileURLWithPath: canonical, isDirectory: true).lastPathComponent
            let components = canonical.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
            return uniqueNormalizedPreservingOrder(
                [trimmed, canonical, abbreviated, basename] + components
            )
        }
    }

    private static func branchTokensForSearch(
        _ rawBranch: String,
        detail: MetadataDetail
    ) -> [String] {
        let trimmed = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        switch detail {
        case .workspace:
            return [trimmed]
        case .surface:
            let components = trimmed.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
            return uniqueNormalizedPreservingOrder([trimmed] + components)
        }
    }

    private static func portTokensForSearch(_ port: Int) -> [String] {
        guard (1...65535).contains(port) else { return [] }
        let portText = String(port)
        return [portText, ":\(portText)"]
    }

    private static func descriptionTokensForSearch(_ rawDescription: String?) -> [String] {
        let trimmed = rawDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return [] }
        let normalizedWhitespace = trimmed.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        let components = normalizedWhitespace.components(separatedBy: metadataDelimiters).filter { !$0.isEmpty }
        return uniqueNormalizedPreservingOrder([trimmed, normalizedWhitespace] + components)
    }

    private static func uniqueNormalizedPreservingOrder(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        result.reserveCapacity(values.count)

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalizedKey = trimmed
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            guard seen.insert(normalizedKey).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
