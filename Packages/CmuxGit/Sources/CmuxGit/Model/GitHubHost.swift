public import Foundation

/// A GitHub-family host that cmux can query through the GitHub REST API.
///
/// `github.com` uses the public GitHub API, while GitHub Enterprise Server
/// hosts use their own `/api/v3/` endpoint. Carry this value with repository
/// references so API routing and token lookup remain host-scoped.
public struct GitHubHost: Hashable, Sendable {
    /// The bare, lowercased hostname, such as `github.com` or `ghe.example.com`.
    public let hostname: String

    /// The explicit HTTPS API port from the remote URL, when it is non-default.
    public let port: Int?

    /// Creates a host from a raw hostname and optional HTTPS API port.
    ///
    /// - Parameters:
    ///   - hostname: The bare host name or IPv6 literal.
    ///   - port: An explicit HTTPS API port, or `nil` for the default.
    public init(hostname: String, port: Int? = nil) {
        self.hostname = hostname.lowercased()
        self.port = (port == 80 || port == 443) ? nil : port
    }

    /// The canonical public GitHub host.
    public static let dotCom = GitHubHost(hostname: "github.com")

    /// Whether this host is the public GitHub SaaS host.
    ///
    /// The port is ignored because public GitHub API requests always go to
    /// `api.github.com`, even when a clone URL carried a proxy port.
    public var isDotCom: Bool { hostname == "github.com" }

    /// The `host[:port]` authority for this host, IPv6-bracketed.
    ///
    /// Used as both the REST API origin and the `gh auth token --hostname`
    /// argument so credential lookup stays consistent with the origin that
    /// requests target: a token stored for `ghe.example.com` is never sent to a
    /// different `ghe.example.com:8443` origin.
    public var authority: String {
        let encodedHost = hostname.contains(":") ? "[\(hostname)]" : hostname
        guard let port else { return encodedHost }
        return "\(encodedHost):\(port)"
    }

    /// The REST API base URL for this host.
    ///
    /// `github.com` maps to `https://api.github.com/`; enterprise hosts map to
    /// `https://<host>[:port]/api/v3/`. The result is optional so malformed
    /// parsed hosts are skipped instead of accidentally falling back to dot-com.
    public var apiBaseURL: URL? {
        if isDotCom {
            return URL(string: "https://api.github.com/")
        }

        return URL(string: "https://\(authority)/api/v3/")
    }

    /// Builds an absolute API URL for an endpoint path relative to ``apiBaseURL``.
    ///
    /// - Parameter endpoint: A path and optional query, such as
    ///   `repos/owner/repo/pulls?state=all`.
    /// - Returns: The absolute REST URL, or `nil` if either component is invalid.
    public func apiURL(endpoint: String) -> URL? {
        guard let base = apiBaseURL else { return nil }
        return URL(string: endpoint, relativeTo: base)?.absoluteURL
    }

    /// A command runner used to resolve a token without tying tests to `gh`.
    public typealias TokenCommandRunner = @Sendable (_ executable: String, _ arguments: [String]) async -> String?

    /// Looks up a GitHub CLI token for this host.
    ///
    /// The lookup uses ``authority`` (host and any non-default port), not the
    /// bare hostname, so the credential matches the origin requests target.
    ///
    /// - Parameter runner: The shell-out closure that invokes `gh`.
    /// - Returns: The trimmed token, or `nil` when no token is available.
    public func authToken(using runner: TokenCommandRunner) async -> String? {
        let raw = await runner("gh", ["auth", "token", "--hostname", authority])
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the PR poller may issue API requests to this host.
    ///
    /// Public GitHub can serve public repositories anonymously. Every other host
    /// requires a token, which also gates non-GitHub hosts out without a host
    /// allowlist.
    ///
    /// - Parameter token: The host-scoped token, or `nil`.
    /// - Returns: `true` when polling this host is allowed.
    public func isPollable(token: String?) -> Bool {
        isDotCom || token?.isEmpty == false
    }
}
