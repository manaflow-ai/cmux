public import Foundation

/// A host-qualified identifier for a single repository on a git hosting service.
///
/// Unlike a bare ``owner``/``name`` slug, a reference preserves the **host** it was
/// cloned from, so cmux can poll the right hosting provider (github.com, a GitHub
/// Enterprise Server instance, gitlab.com, a self-hosted GitLab, bitbucket.org, or
/// any other host described in the user's configuration) instead of assuming every
/// remote lives on github.com.
///
/// Parse one from a git remote URL with ``parse(remoteURL:)`` (handles SCP-style
/// SSH, `ssh://`, `https://`, `http://`, and `git://` forms) or from a web URL with
/// ``parse(webURL:)``. The host is preserved verbatim (lowercased); the path keeps
/// every segment, so GitLab subgroups (`group/subgroup/project`) survive intact.
///
/// ```swift
/// let ref = GitRemoteReference.parse(remoteURL: "git@gitlab.example.com:team/app.git")
/// ref?.host        // "gitlab.example.com"
/// ref?.path        // "team/app"
/// ref?.identity    // "gitlab.example.com/team/app"
/// ```
public struct GitRemoteReference: Sendable, Equatable, Hashable {
    /// The lowercased host the repository was cloned from, without any port.
    public let host: String

    /// The HTTPS port to target the host's REST API on, when the remote pinned a
    /// non-default port via an `https://host:port/...` URL; otherwise `nil`.
    ///
    /// SSH ports (from `ssh://` or SCP remotes) are intentionally ignored because
    /// they do not describe where the hosting provider's HTTPS API lives.
    public let httpsPort: Int?

    /// The repository path with every segment preserved, no leading or trailing
    /// slash, and no `.git` suffix (e.g. `owner/repo` or `group/subgroup/project`).
    public let path: String

    /// Creates a reference from already-normalized parts.
    ///
    /// - Parameters:
    ///   - host: The lowercased host without a port.
    ///   - httpsPort: An explicit HTTPS API port, or `nil` for the default.
    ///   - path: The repository path (`owner/repo`, segments preserved).
    public init(host: String, httpsPort: Int? = nil, path: String) {
        self.host = host
        self.httpsPort = httpsPort
        self.path = path
    }

    /// The host with its explicit HTTPS port appended when one was pinned.
    public var hostWithPort: String {
        if let httpsPort {
            return "\(host):\(httpsPort)"
        }
        return host
    }

    /// The first path segment, i.e. the repository owner / top-level namespace.
    public var owner: String {
        path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
    }

    /// The last path segment, i.e. the repository name.
    public var name: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// A stable, host-qualified cache key of the form `host[:port]/path`.
    public var identity: String {
        "\(hostWithPort)/\(path)"
    }

    /// Parses a git remote URL into a host-qualified reference.
    ///
    /// Accepts SCP-style SSH (`git@host:owner/repo.git`), `ssh://`, `https://`,
    /// `http://`, and `git://` forms. Returns `nil` when the URL has no host or
    /// fewer than two path segments.
    ///
    /// - Parameter remoteURL: A `git remote -v` fetch URL.
    /// - Returns: The parsed reference, or `nil` if it is not a usable repo URL.
    public static func parse(remoteURL: String) -> GitRemoteReference? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains("://"),
           let scp = parseScpLike(trimmed) {
            return scp
        }

        guard let components = URLComponents(string: trimmed),
              let rawHost = components.host,
              !rawHost.isEmpty else {
            return nil
        }

        let scheme = components.scheme?.lowercased()
        let httpsPort = (scheme == "https" || scheme == "http") ? components.port : nil
        return make(host: rawHost, httpsPort: httpsPort, rawPath: components.path)
    }

    /// Parses a repository web URL (e.g. a pull request URL) into a reference.
    ///
    /// - Parameter webURL: An `https://host/owner/repo/...` style URL.
    /// - Returns: The parsed reference, or `nil` if it has no host or path.
    public static func parse(webURL: URL) -> GitRemoteReference? {
        guard let host = webURL.host, !host.isEmpty else { return nil }
        let scheme = webURL.scheme?.lowercased()
        let httpsPort = (scheme == "https" || scheme == "http") ? webURL.port : nil
        return make(host: host, httpsPort: httpsPort, rawPath: webURL.path)
    }

    private static func parseScpLike(_ value: String) -> GitRemoteReference? {
        // SCP form: [user@]host:path. There is no scheme, and the colon separates
        // host from path. Reject values whose pre-colon segment already contains a
        // slash (that would be a bare filesystem path, not a remote).
        let afterUser = value.split(separator: "@", maxSplits: 1).last.map(String.init) ?? value
        // Bracketed IPv6 literal host: [::1]:owner/repo.
        if afterUser.hasPrefix("["), let bracketEnd = afterUser.range(of: "]:") {
            let host = String(afterUser[afterUser.index(after: afterUser.startIndex)..<bracketEnd.lowerBound])
            guard !host.isEmpty else { return nil }
            return make(host: host, httpsPort: nil, rawPath: String(afterUser[bracketEnd.upperBound...]))
        }
        guard let colonIndex = afterUser.firstIndex(of: ":") else { return nil }
        let host = String(afterUser[..<colonIndex])
        let rawPath = String(afterUser[afterUser.index(after: colonIndex)...])
        guard !host.contains("/"), !host.isEmpty else { return nil }
        return make(host: host, httpsPort: nil, rawPath: rawPath)
    }

    private static func make(host: String, httpsPort: Int?, rawPath: String) -> GitRemoteReference? {
        let normalizedHost = host.lowercased()
        // Drop default HTTP(S) ports so `host` and `host:443` are one cache identity.
        let normalizedPort = (httpsPort == 443 || httpsPort == 80) ? nil : httpsPort
        let path = normalizedRepositoryPath(rawPath)
        guard let path else { return nil }
        return GitRemoteReference(host: normalizedHost, httpsPort: normalizedPort, path: path)
    }

    private static func normalizedRepositoryPath(_ rawPath: String) -> String? {
        var trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix(".git") {
            trimmed.removeLast(4)
        }
        trimmed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        let segments = trimmed.split(separator: "/").map(String.init)
        guard segments.count >= 2, segments.allSatisfy({ !$0.isEmpty }) else { return nil }
        return segments.joined(separator: "/")
    }
}
