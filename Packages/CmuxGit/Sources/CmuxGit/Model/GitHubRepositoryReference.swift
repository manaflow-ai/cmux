public import Foundation

/// A host-qualified GitHub-family repository reference.
///
/// This is the identity used by the sidebar PR poller. It keeps the host next
/// to `owner/repo`, so repositories with the same slug on different GitHub
/// Enterprise Server hosts do not share cache entries, tokens, or API bases.
public struct GitHubRepositoryReference: Hashable, Sendable {
    /// The host that owns the repository.
    public let host: GitHubHost
    /// The repository owner or organization.
    public let owner: String
    /// The repository name without a trailing `.git`.
    public let repo: String

    /// Creates a repository reference from parsed components.
    ///
    /// - Parameters:
    ///   - host: The repository host.
    ///   - owner: The repository owner or organization.
    ///   - repo: The repository name without `.git`.
    public init(host: GitHubHost, owner: String, repo: String) {
        self.host = host
        self.owner = owner
        self.repo = repo
    }

    /// The `owner/repo` path used in REST endpoints.
    public var slug: String { "\(owner)/\(repo)" }

    /// A stable `host/owner/repo` description for logs and tests.
    public var hostQualifiedSlug: String { "\(host.hostname)/\(slug)" }

    /// Parses a git remote URL into a host-qualified reference.
    ///
    /// - Parameter remoteURL: A remote URL in SCP-style SSH, `ssh://`,
    ///   `https://`, `http://`, or `git://` form.
    /// - Returns: The parsed reference, or `nil` if no host or `owner/repo`
    ///   path is present.
    public static func parse(remoteURL: String) -> GitHubRepositoryReference? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains("://"), let reference = parseSCPLike(trimmed) {
            return reference
        }

        guard let url = URL(string: trimmed),
              let host = url.host,
              !host.isEmpty,
              let (owner, repo) = ownerRepo(fromPath: url.path) else {
            return nil
        }

        return GitHubRepositoryReference(
            host: GitHubHost(hostname: host, port: apiPort(of: url)),
            owner: owner,
            repo: repo
        )
    }

    /// Parses a web URL, such as a pull request URL, into a repository reference.
    ///
    /// - Parameter webURL: A URL with `/<owner>/<repo>/...` in its path.
    /// - Returns: The parsed reference, or `nil` if no host or repository path
    ///   is present.
    public static func parse(webURL: URL) -> GitHubRepositoryReference? {
        guard let host = webURL.host,
              !host.isEmpty,
              let (owner, repo) = ownerRepo(fromPath: webURL.path) else {
            return nil
        }

        return GitHubRepositoryReference(
            host: GitHubHost(hostname: host, port: apiPort(of: webURL)),
            owner: owner,
            repo: repo
        )
    }

    /// The HTTPS API port to preserve from an HTTP(S) remote.
    private static func apiPort(of url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "http":
            return url.port == 80 ? nil : url.port
        case "https":
            return url.port == 443 ? nil : url.port
        default:
            return nil
        }
    }

    /// Parses SCP-like SSH remotes, including bracketed IPv6 hosts.
    private static func parseSCPLike(_ remoteURL: String) -> GitHubRepositoryReference? {
        let searchStart = remoteURL.firstIndex(of: "]").map { remoteURL.index(after: $0) }
            ?? remoteURL.startIndex
        guard let colonIndex = remoteURL[searchStart...].firstIndex(of: ":") else { return nil }

        let authority = String(remoteURL[..<colonIndex])
        let path = String(remoteURL[remoteURL.index(after: colonIndex)...])

        var host = authority
        if let atIndex = host.lastIndex(of: "@") {
            host = String(host[host.index(after: atIndex)...])
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        guard !host.isEmpty,
              let (owner, repo) = ownerRepo(fromPath: path) else {
            return nil
        }
        return GitHubRepositoryReference(host: GitHubHost(hostname: host), owner: owner, repo: repo)
    }

    /// Splits a path into owner and repo, stripping a trailing `.git`.
    private static func ownerRepo(fromPath rawPath: String) -> (owner: String, repo: String)? {
        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else { return nil }

        let components = trimmedPath.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }

        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo.removeLast(4)
        }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return (owner, repo)
    }
}
