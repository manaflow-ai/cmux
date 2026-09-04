import Foundation

/// Search scope for one bounded catalog query.
public enum ArtifactSearchScope: Equatable, Sendable {
    /// Search records owned by a workspace.
    case workspace(String)
    /// Search records owned by a project.
    case project(String)
    /// Search all permitted local records.
    case global
}

/// Coarse kind groups used by the Artifacts surface without losing the typed
/// ``ArtifactKind`` value on each record.
public enum ArtifactKindGroup: String, Codable, CaseIterable, Sendable {
    /// HTTP(S) and legacy file URL records.
    case links
    /// Inline or file-backed HTML documents.
    case html
    /// Every non-link, non-HTML artifact.
    case files
}

/// A cancellable, bounded search request.
public struct ArtifactSearchQuery: Equatable, Sendable {
    /// User-entered text; empty text means list newest records.
    public let text: String
    /// Scope to apply before matching fields.
    public let scope: ArtifactSearchScope
    /// Maximum result count requested by the caller.
    public let limit: Int
    /// Optional artifact-kind filter.
    public let kind: ArtifactKind?
    /// Optional coarse kind group filter.
    public let kindGroup: ArtifactKindGroup?
    /// Optional producer/source filter.
    public let source: ArtifactSource?
    /// Optional normalized host filter retained for Links compatibility.
    public let host: String?

    /// Creates a search request.
    public init(
        text: String = "",
        scope: ArtifactSearchScope = .global,
        limit: Int = 500,
        kind: ArtifactKind? = nil,
        kindGroup: ArtifactKindGroup? = nil,
        source: ArtifactSource? = nil,
        host: String? = nil
    ) {
        self.text = String(decoding: Array(text.utf8.prefix(4_096)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.scope = scope
        self.limit = limit
        self.kind = kind
        self.kindGroup = kindGroup
        self.source = source
        self.host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// One record returned from a catalog search.
public struct ArtifactSearchResult: Equatable, Sendable, Identifiable {
    /// The matched record.
    public let record: ArtifactRecord
    /// Higher scores are shown first.
    public let score: Int
    /// A bounded content line when the match came from inline content.
    public let snippet: String?

    /// Stable result identity.
    public var id: UUID { record.id }

    /// Creates a search result.
    public init(record: ArtifactRecord, score: Int, snippet: String? = nil) {
        self.record = record
        self.score = score
        self.snippet = snippet
    }
}

/// Pure bounded matcher used by the repository actor.
public struct ArtifactSearchEngine: Sendable {
    /// Creates a matcher.
    public init() {}

    /// Searches records without filesystem access.
    ///
    /// - Parameters:
    ///   - records: Immutable catalog records to inspect.
    ///   - query: Bounded search request.
    /// - Returns: Deterministically ordered results.
    public func results(
        records: [ArtifactRecord],
        query: ArtifactSearchQuery
    ) throws -> [ArtifactSearchResult] {
        try Task.checkCancellation()
        let needle = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedLimit = min(max(query.limit, 1), 5_000)
        var matches: [ArtifactSearchResult] = []
        matches.reserveCapacity(min(records.count, boundedLimit))
        for record in records {
            try Task.checkCancellation()
            guard Self.matchesScope(record, scope: query.scope) else { continue }
            if let kind = query.kind, record.kind != kind { continue }
            if let group = query.kindGroup, !Self.matchesGroup(record, group: group) { continue }
            if let source = query.source, record.source != source { continue }
            if let host = query.host, record.hostKey?.lowercased() != host { continue }
            guard !needle.isEmpty else {
                matches.append(ArtifactSearchResult(record: record, score: 0))
                continue
            }
            let fields = record.searchableFields
            var score = Int.min
            for (field, weight) in fields {
                if field.localizedStandardContains(needle) {
                    score = max(score, weight)
                }
            }
            guard score != Int.min else { continue }
            let snippet: String? = {
                guard let content = record.inlineContent ?? record.metadata["contentPreview"],
                      let range = content.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
                    return nil
                }
                let lineStart = content[..<range.lowerBound].lastIndex(of: "\n").map { content.index(after: $0) } ?? content.startIndex
                let lineEnd = content[range.upperBound...].firstIndex(of: "\n") ?? content.endIndex
                return String(content[lineStart..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
            }()
            matches.append(ArtifactSearchResult(record: record, score: score, snippet: snippet))
            if matches.count >= boundedLimit * 2 { break }
        }
        try Task.checkCancellation()
        return matches.sorted { (lhs: ArtifactSearchResult, rhs: ArtifactSearchResult) in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.record.lastSeenAt != rhs.record.lastSeenAt { return lhs.record.lastSeenAt > rhs.record.lastSeenAt }
            return lhs.record.id.uuidString < rhs.record.id.uuidString
        }.prefix(boundedLimit).map { $0 }
    }

    private static func matchesScope(_ record: ArtifactRecord, scope: ArtifactSearchScope) -> Bool {
        switch scope {
        case .global: true
        case .workspace(let id): record.ownership.workspaceID == id
        case .project(let id): record.ownership.projectID == id
        }
    }

    private static func matchesGroup(_ record: ArtifactRecord, group: ArtifactKindGroup) -> Bool {
        switch group {
        case .links:
            record.isURLLike
        case .html:
            record.kind == .html
        case .files:
            !record.isURLLike && record.kind != .html
        }
    }
}
