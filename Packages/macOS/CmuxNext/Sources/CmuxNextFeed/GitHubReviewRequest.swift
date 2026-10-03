import Foundation

/// A review request returned by GitHub's issue search endpoint.
public nonisolated struct GitHubReviewRequest: Decodable, Sendable, Equatable {
    public struct Repository: Codable, Sendable, Equatable {
        public var fullName: String
        public var htmlURL: String?

        public init(fullName: String, htmlURL: String? = nil) {
            self.fullName = fullName
            self.htmlURL = htmlURL
        }
    }

    public struct User: Codable, Sendable, Equatable {
        public var login: String

        public init(login: String) { self.login = login }
    }

    public var id: Int
    public var number: Int
    public var title: String
    public var htmlURL: String
    public var repository: Repository
    public var user: User?
    public var body: String?
    public var state: String?
    public var branch: String?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, number, title, repository, user, body, state
        case htmlURL = "html_url"
        case repositoryURL = "repository_url"
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }

    public init(
        id: Int, number: Int, title: String, htmlURL: String,
        repository: Repository, user: User? = nil, body: String? = nil,
        state: String? = nil, branch: String? = nil, updatedAt: Date
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.htmlURL = htmlURL
        self.repository = repository
        self.user = user
        self.body = body
        self.state = state
        self.branch = branch
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        htmlURL = try c.decode(String.self, forKey: .htmlURL)
        user = try c.decodeIfPresent(User.self, forKey: .user)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        if let explicitRepository = try c.decodeIfPresent(Repository.self, forKey: .repository) {
            repository = explicitRepository
        } else if let repositoryURL = try c.decodeIfPresent(String.self, forKey: .repositoryURL) {
            let pieces = repositoryURL.split(separator: "/")
            repository = Repository(fullName: pieces.suffix(2).map(String.init).joined(separator: "/"))
        } else {
            repository = Repository(fullName: "")
        }
        if let pullRequest = try c.decodeIfPresent(PullRequest.self, forKey: .pullRequest) {
            branch = pullRequest.head?.ref
        } else {
            branch = nil
        }
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    private struct PullRequest: Decodable {
        struct Head: Decodable { var ref: String? }
        var head: Head?
    }
}
