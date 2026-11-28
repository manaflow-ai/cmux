public import Foundation

/// Live GitHub content for one feed id. It is never sent to or persisted by the feed owner.
public nonisolated struct GitHubFeedDetail: Sendable, Equatable {
    public var repository: String
    public var number: Int?
    public var url: URL?
    public var title: String
    public var body: String?
    public var state: String?
    public var branch: String?
    public var checks: [GitHubCheck]
    public var updatedAt: Date

    public init(
        repository: String, number: Int? = nil, url: URL? = nil, title: String,
        body: String? = nil, state: String? = nil, branch: String? = nil,
        checks: [GitHubCheck] = [], updatedAt: Date
    ) {
        self.repository = repository
        self.number = number
        self.url = url
        self.title = title
        self.body = body
        self.state = state
        self.branch = branch
        self.checks = checks
        self.updatedAt = updatedAt
    }
}
