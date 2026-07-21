import Foundation

/// Filename or content match returned by artifact search.
public struct ArtifactSearchResult: Identifiable, Equatable, Sendable {
    /// Result identity, equal to the artifact's relative path.
    public let id: String
    /// Matched file node.
    public let node: ArtifactNode
    /// Relevance score; larger values sort first.
    public let score: Int
    /// Whether searchable file contents matched the query.
    public let matchedContent: Bool
    /// Short single-line content excerpt when available.
    public let snippet: String?

    /// Creates an artifact search result.
    ///
    /// - Parameters:
    ///   - node: Matched file node.
    ///   - score: Relevance score used for ordering.
    ///   - matchedContent: Whether file contents matched.
    ///   - snippet: Bounded single-line content excerpt.
    public init(node: ArtifactNode, score: Int, matchedContent: Bool, snippet: String?) {
        self.id = node.relativePath
        self.node = node
        self.score = score
        self.matchedContent = matchedContent
        self.snippet = snippet
    }
}
