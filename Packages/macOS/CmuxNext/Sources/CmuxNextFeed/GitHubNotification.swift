import Foundation

/// The small subset of a notification used by the feed source.
public nonisolated struct GitHubNotification: Codable, Sendable, Equatable {
    public struct Subject: Codable, Sendable, Equatable {
        public var title: String
        public var url: String?
        public var type: String?

        public init(title: String, url: String? = nil, type: String? = nil) {
            self.title = title
            self.url = url
            self.type = type
        }
    }

    public struct Repository: Codable, Sendable, Equatable {
        public var fullName: String
        public var htmlURL: String?

        enum CodingKeys: String, CodingKey { case fullName = "full_name", htmlURL = "html_url" }

        public init(fullName: String, htmlURL: String? = nil) {
            self.fullName = fullName
            self.htmlURL = htmlURL
        }
    }

    public var id: String
    public var reason: String
    public var subject: Subject
    public var repository: Repository
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, reason, subject, repository
        case updatedAt = "updated_at"
    }

    public init(id: String, reason: String, subject: Subject, repository: Repository, updatedAt: Date) {
        self.id = id
        self.reason = reason
        self.subject = subject
        self.repository = repository
        self.updatedAt = updatedAt
    }
}
