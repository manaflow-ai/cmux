import Foundation

/// A host-qualified reference to a GitHub-family repository (`host` + `owner` + `repo`).
///
/// Parsed from a git remote URL (or a web URL), this is the unit of identity the
/// workspace pull-request poller keys its caches and requests on. Carrying the
/// ``GitHubHost`` alongside `owner`/`repo` is what lets the poller work against
/// GitHub Enterprise Server hosts instead of only github.com: two repositories
/// with the same `owner/repo` slug on different hosts are distinct references.
///
/// Parsing is deliberately host-agnostic — a gitlab.com or bitbucket.org URL
/// parses into a reference just like a GHES URL would. Whether a reference is
/// actually polled is decided later by token availability
/// (``GitHubHost/isPollable(token:)``), not by an allowlist of hostnames.
struct GitHubRepositoryReference: Hashable, Sendable {
    /// The host the repository lives on.
    let host: GitHubHost
    /// The repository owner (user or organization).
    let owner: String
    /// The repository name, without any trailing `.git`.
    let repo: String

    /// The `owner/repo` path used in REST API endpoints (e.g. `repos/<slug>/pulls`).
    var slug: String { "\(owner)/\(repo)" }

    /// A stable `host/owner/repo` description, useful for debug logging and tests.
    var hostQualifiedSlug: String { "\(host.hostname)/\(slug)" }

    /// Parses a git remote URL into a host-qualified reference.
    ///
    /// - Parameter remoteURL: A git remote URL in SCP-style SSH
    ///   (`git@host:owner/repo.git`), `ssh://`, `https://`, `http://`, or
    ///   `git://` form, with or without a trailing `.git` and with optional
    ///   trailing slashes.
    /// - Returns: The parsed reference, or `nil` when the URL has no host or no
    ///   `owner/repo` path.
    static func parse(remoteURL: String) -> GitHubRepositoryReference? {
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
        return GitHubRepositoryReference(host: GitHubHost(hostname: host), owner: owner, repo: repo)
    }

    /// Parses SCP-style SSH remotes (`git@host:owner/repo.git`).
    private static func parseSCPLike(_ remoteURL: String) -> GitHubRepositoryReference? {
        guard let colonIndex = remoteURL.firstIndex(of: ":") else { return nil }
        let authority = String(remoteURL[..<colonIndex])
        let path = String(remoteURL[remoteURL.index(after: colonIndex)...])
        let host: String
        if let atIndex = authority.lastIndex(of: "@") {
            host = String(authority[authority.index(after: atIndex)...])
        } else {
            host = authority
        }
        guard !host.isEmpty, let (owner, repo) = Self.ownerRepo(fromPath: path) else { return nil }
        return GitHubRepositoryReference(host: GitHubHost(hostname: host), owner: owner, repo: repo)
    }

    /// Parses a repository web URL (e.g. a pull-request URL) into a reference.
    ///
    /// - Parameter webURL: A `https://host/owner/repo/...` URL.
    /// - Returns: The parsed reference, or `nil` when the URL has no host or no
    ///   `owner/repo` path.
    static func parse(webURL: URL) -> GitHubRepositoryReference? {
        guard let host = webURL.host, !host.isEmpty,
              let (owner, repo) = Self.ownerRepo(fromPath: webURL.path) else {
            return nil
        }
        return GitHubRepositoryReference(host: GitHubHost(hostname: host), owner: owner, repo: repo)
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
