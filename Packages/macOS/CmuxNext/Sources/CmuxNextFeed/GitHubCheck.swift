public import Foundation

/// A check that caused a GitHub notice. Content is retained by the client only.
public nonisolated struct GitHubCheck: Sendable, Equatable, Hashable {
    public var name: String
    public var conclusion: String?
    public var url: URL?

    public init(name: String, conclusion: String? = nil, url: URL? = nil) {
        self.name = name
        self.conclusion = conclusion
        self.url = url
    }
}
