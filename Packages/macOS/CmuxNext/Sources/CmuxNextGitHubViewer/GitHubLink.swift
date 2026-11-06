public import Foundation
public import CmuxNextAgentPane

/// A github.com pull request link, by the chat's own rule (``AgentPaneReplyRequest/pullRequestURL(_:)``):
/// `https://github.com/<owner>/<repo>/pull/<n>`, or one of its tabs (`/files`), with no query or
/// fragment. Only its Files tab opens natively (``GitHubPullRequestDiff``); the pull request itself,
/// and anything else, opens its web page.
public nonisolated struct GitHubLink: Equatable, Sendable {
    /// The pull request's plain address, rebuilt from its parts (the cache's and gh's key).
    public let url: URL
    /// `owner/repo`.
    public let repository: String
    public let number: Int
    /// The link names the pull request's Files tab (`/pull/N/files`, Session Info's View diff): it
    /// opens the diff itself, not the web page.
    public let files: Bool

    public init?(_ url: URL) {
        guard let plain = AgentPaneReplyRequest.pullRequestURL(url.absoluteString) else { return nil }
        let parts = plain.path.split(separator: "/").map(String.init)
        guard parts.count == 4, let number = Int(parts[3]) else { return nil }
        self.url = plain
        repository = parts[0] + "/" + parts[1]
        self.number = number
        files = url.path(percentEncoded: true).split(separator: "/").last == "files"
    }

    /// The Files tab's web page, where a diff that could not be read opens instead.
    public var filesURL: URL { url.appendingPathComponent("files") }

    /// `owner/repo#n`, the diff tab's title.
    public var reference: String { "\(repository)#\(number)" }

    /// The link a saved GitHub page route names (`#/pull?url=<address>`, the retired page's tabs),
    /// nil for any other route.
    public init?(route: String) {
        let trimmed = route.hasPrefix("#") ? String(route.dropFirst()) : route
        guard trimmed.hasPrefix("/pull?"), let components = URLComponents(string: "x:" + trimmed.dropFirst("/pull".count)),
              let address = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: address) else { return nil }
        self.init(url)
    }
}
