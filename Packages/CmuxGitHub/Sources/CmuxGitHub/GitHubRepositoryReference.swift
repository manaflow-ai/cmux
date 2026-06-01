public import Foundation

/// A host-qualified reference to a GitHub-family repository (`host` + `owner` + `repo`).
///
/// Parsed from a git remote URL (or a web URL), this is the unit of identity a
/// pull-request poller keys its caches and requests on. Carrying the
/// ``GitHubHost`` alongside `owner`/`repo` is what lets a poller work against
/// GitHub Enterprise Server hosts instead of only github.com: two repositories
/// with the same `owner/repo` slug on different hosts are distinct references.
///
/// Parsing is deliberately host-agnostic — a gitlab.com or bitbucket.org URL
/// parses into a reference just like a GHES URL would. Whether a reference is
/// actually polled is decided later by token availability
/// (``GitHubHost/isPollable(token:)``), not by an allowlist of hostnames.
public struct GitHubRepositoryReference: Hashable, Sendable {
    /// The host the repository lives on.
    public let host: GitHubHost
    /// The repository owner (user or organization).
    public let owner: String
    /// The repository name, without any trailing `.git`.
    public let repo: String

    /// Creates a reference from its components.
    ///
    /// - Parameters:
    ///   - host: The host the repository lives on.
    ///   - owner: The repository owner.
    ///   - repo: The repository name (without `.git`).
    public init(host: GitHubHost, owner: String, repo: String) {
        self.host = host
        self.owner = owner
        self.repo = repo
    }

    /// The `owner/repo` path used in REST API endpoints (e.g. `repos/<slug>/pulls`).
    public var slug: String { "\(owner)/\(repo)" }

    /// A stable `host/owner/repo` description, useful for debug logging and tests.
    public var hostQualifiedSlug: String { "\(host.hostname)/\(slug)" }

    /// Parses a git remote URL into a host-qualified reference.
    ///
    /// - Parameter remoteURL: A git remote URL in SCP-style SSH
    ///   (`git@host:owner/repo.git`), `ssh://`, `https://`, `http://`, or
    ///   `git://` form, with or without a trailing `.git` and with optional
    ///   trailing slashes.
    /// - Returns: The parsed reference, or `nil` when the URL has no host or no
    ///   `owner/repo` path.
    public static func parse(remoteURL: String) -> GitHubRepositoryReference? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // SCP-style SSH syntax: `[user@]host:owner/repo(.git)`. It has no scheme,
        // so it cannot be parsed by `URL`; recognize it by the absence of `://`.
        if !trimmed.contains("://"), let reference = Self.parseSCPLike(trimmed) {
            return reference
        }

        guard let url = URL(string: trimmed),
              let host = url.host, !host.isEmpty,
              let (owner, repo) = Self.ownerRepo(fromPath: url.path) else {
            return nil
        }
        return GitHubRepositoryReference(
            host: GitHubHost(hostname: host, port: Self.apiPort(of: url)),
            owner: owner,
            repo: repo
        )
    }

    /// The HTTPS REST API port to carry for a remote, or `nil`.
    ///
    /// Only `http`/`https` remotes contribute a port. An `ssh://` or `git://`
    /// port is a transport port (e.g. `2222`), not the REST API port, so it must
    /// not leak into ``GitHubHost/apiBaseURL``.
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

    /// Parses SCP-style SSH remotes (`git@host:owner/repo.git`).
    private static func parseSCPLike(_ remoteURL: String) -> GitHubRepositoryReference? {
        // The authority/path separator is the first ':' that follows the host.
        // For a bracketed IPv6 host (`git@[::1]:owner/repo`) that ':' comes after
        // the closing bracket; otherwise it is simply the first ':'. Searching
        // from after any ']' avoids splitting inside the address literal.
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
        guard !host.isEmpty, let (owner, repo) = Self.ownerRepo(fromPath: path) else { return nil }
        return GitHubRepositoryReference(host: GitHubHost(hostname: host), owner: owner, repo: repo)
    }

    /// Parses a repository web URL (e.g. a pull-request URL) into a reference.
    ///
    /// - Parameter webURL: A `https://host/owner/repo/...` URL.
    /// - Returns: The parsed reference, or `nil` when the URL has no host or no
    ///   `owner/repo` path.
    public static func parse(webURL: URL) -> GitHubRepositoryReference? {
        guard let host = webURL.host, !host.isEmpty,
              let (owner, repo) = Self.ownerRepo(fromPath: webURL.path) else {
            return nil
        }
        return GitHubRepositoryReference(
            host: GitHubHost(hostname: host, port: Self.apiPort(of: webURL)),
            owner: owner,
            repo: repo
        )
    }

    /// Splits a URL path into `owner` and `repo`, stripping a trailing `.git`.
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
