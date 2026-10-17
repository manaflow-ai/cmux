/// A web search performed by an agent, including the sources it surfaced.
///
/// Search results are kept as a first-class transcript item so the mobile
/// client can render source cards and preserve the links when a transcript is
/// paged or replayed. Producers may emit a search before its sources are
/// known; a later transcript item can carry the citation list.
public struct ChatWebSearch: Sendable, Equatable, Codable {
    /// One source returned by the search provider.
    public struct Source: Sendable, Equatable, Codable, Identifiable {
        /// Stable identity for SwiftUI and transcript reconciliation.
        public let id: String
        /// Human-readable page title, when supplied by the provider.
        public let title: String?
        /// Canonical URL for the source.
        public let url: String
        /// Short provider-provided excerpt, when available.
        public let snippet: String?

        public init(id: String? = nil, title: String? = nil, url: String, snippet: String? = nil) {
            self.url = url
            self.id = id ?? url
            self.title = title
            self.snippet = snippet
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, url, snippet
        }
    }

    /// The search query, when it is known.
    public let query: String?
    /// Whether the search completed successfully.
    public let status: ChatToolUse.Status
    /// Sources returned or cited by the search.
    public let sources: [Source]

    public init(query: String? = nil, status: ChatToolUse.Status = .succeeded, sources: [Source] = []) {
        self.query = query
        self.status = status
        self.sources = sources
    }

    private enum CodingKeys: String, CodingKey {
        case query, status, sources
    }
}
