import Foundation

/// The repository coordinates of a pull request, parsed out of its review URL.
///
/// Used to render the same pull request at another review host. Parsing is
/// host-agnostic so that enterprise hosts still resolve against a custom
/// template; only the `/{owner}/{repo}/pull/{number}` path shape is required.
///
/// ```swift
/// PullRequestLinkReference(pullRequestURL: URL(string: "https://github.com/manaflow-ai/cmux/pull/9641")!)
/// // owner: "manaflow-ai", repo: "cmux", number: 9641
/// ```
public struct PullRequestLinkReference: Equatable, Sendable {
    /// The repository owner (user or organization).
    public let owner: String

    /// The repository name.
    public let repo: String

    /// The pull request number.
    public let number: Int

    /// Creates a reference from explicit coordinates.
    ///
    /// - Parameters:
    ///   - owner: The repository owner.
    ///   - repo: The repository name.
    ///   - number: The pull request number.
    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    /// Parses a reference out of a pull request URL.
    ///
    /// - Parameter pullRequestURL: An `http` or `https` URL with a host whose path
    ///   is exactly `/{owner}/{repo}/pull/{number}`. GitHub's `html_url` has this
    ///   shape. An empty authority (`https:///owner/repo/pull/1`) parses as that
    ///   path with a `nil` host, so the host is checked explicitly.
    /// - Returns: `nil` when the scheme or path shape does not match, in which
    ///   case callers keep the original URL rather than rewriting it. Deeper
    ///   paths (`/pull/42/files`) and fragments (`#issuecomment-1`) are rejected
    ///   on purpose: they address something more specific than the pull request,
    ///   and no rewrite can carry that target across hosts.
    public init?(pullRequestURL: URL) {
        guard let scheme = pullRequestURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              pullRequestURL.host?.isEmpty == false else {
            return nil
        }
        let segments = pullRequestURL.pathComponents.filter { $0 != "/" }
        guard pullRequestURL.fragment == nil,
              segments.count == 4,
              segments[2].lowercased() == "pull",
              let number = Int(segments[3]),
              number > 0,
              !segments[0].isEmpty,
              !segments[1].isEmpty else {
            return nil
        }
        self.init(owner: segments[0], repo: segments[1], number: number)
    }
}
