/// A pull request associated with a session, as resolved from its working tree.
public struct PullRequestLink: Hashable, Sendable {
    public let number: Int
    public let url: String
    public let repository: String?

    public init(number: Int, url: String, repository: String?) {
        self.number = number
        self.url = url
        self.repository = repository
    }
}
