public import Foundation
public import CmuxNextAgentPane

/// A github.com pull request link, by the chat's own rule (``AgentPaneReplyRequest/pullRequestURL(_:)``):
/// `https://github.com/<owner>/<repo>/pull/<n>`, or one of its tabs (`/files`), with no query or
/// fragment. Only its Files tab (Session Info's View diff) opens in cmux, as the diff
/// (``PullRequestDiff``); every github.com link opens its web page (Leo, 2026-11-06: "stop doing
/// our own renderer for this").
public nonisolated struct GitHubLink: Equatable, Sendable {
    /// The pull request's plain address, rebuilt from its parts (the cache's and gh's key).
    public let url: URL
    /// `owner/repo`.
    public let repository: String
    public let number: Int
    /// The link names the pull request's Files tab (`/pull/N/files`, Session Info's View diff): it
    /// opens the diff itself, not the page.
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

    /// The pull request a tab of the removed GitHub page shows (its saved route `#/pull?url=<address>`),
    /// so a restored one reopens as its web page; nil for any other route.
    public init?(pageRoute route: String?) {
        guard let route, route.contains("?"), let query = route.split(separator: "?", maxSplits: 1).last,
              let address = URLComponents(string: "x:?" + query)?.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: address) else { return nil }
        self.init(url)
    }

    /// `owner/repo#n`, the tab's and the diff tab's title.
    public var reference: String { "\(repository)#\(number)" }
}
