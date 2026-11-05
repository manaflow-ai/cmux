public import Foundation
public import CmuxNextAgentPane

/// A github.com link the GitHub page shows natively instead of loading github.com (Leo, 2026-11-05:
/// "why am I loading a web page every single time?"). Only a pull request so far, by the chat's own
/// rule (``AgentPaneReplyRequest/pullRequestURL(_:)``): `https://github.com/<owner>/<repo>/pull/<n>`,
/// or one of its tabs (`/files`), with no query or fragment. Anything else (an issue, a commit, a
/// comment's `#issuecomment-` anchor) opens its web page as before.
public nonisolated struct GitHubLink: Equatable, Sendable {
    /// The pull request's plain address, rebuilt from its parts (the cache's and gh's key).
    public let url: URL
    /// `owner/repo`.
    public let repository: String
    public let number: Int

    public init?(_ url: URL) {
        guard let plain = AgentPaneReplyRequest.pullRequestURL(url.absoluteString) else { return nil }
        let parts = plain.path.split(separator: "/").map(String.init)
        guard parts.count == 4, let number = Int(parts[3]) else { return nil }
        self.url = plain
        repository = parts[0] + "/" + parts[1]
        self.number = number
    }

    /// `owner/repo#n`, the tab's and the diff tab's title.
    public var reference: String { "\(repository)#\(number)" }

    /// The page's route for this link (`#/pull?url=<address>`), read by webviews/src/pages/github.
    public var route: String {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return "#/pull?" + (query.percentEncodedQuery ?? "")
    }

    /// The link a page route names, nil for any other route.
    public init?(route: String) {
        let trimmed = route.hasPrefix("#") ? String(route.dropFirst()) : route
        guard trimmed.hasPrefix("/pull?"), let components = URLComponents(string: "x:" + trimmed.dropFirst("/pull".count)),
              let address = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let url = URL(string: address) else { return nil }
        self.init(url)
    }
}
