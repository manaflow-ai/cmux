public import Foundation

/// The base address of a subrouter daemon.
///
/// Defaults to the daemon's standard loopback bind, `http://127.0.0.1:31415`.
/// Loopback requests are trusted by the daemon (no token needed). A remote
/// server from the `sr server` registry may require its `adminToken` for
/// the non-loopback `/_subrouter/*` endpoints; the token rides here so the
/// HTTP client can attach it, and is deliberately kept out of `baseURL` —
/// every user-visible rendering of an endpoint (panel header, socket
/// `endpoint` payload, CLI status) reads `baseURL` only.
public struct SubrouterEndpoint: Sendable, Hashable {
    /// The standard daemon address, `http://127.0.0.1:31415`.
    public static let standard = SubrouterEndpoint(
        baseURL: URL(string: "http://127.0.0.1:31415")!
    )

    /// The base URL requests are resolved against.
    public let baseURL: URL

    /// The admin token for non-loopback `/_subrouter/*` endpoints, sent as
    /// `X-Subrouter-Admin-Token`, or `nil` when the daemon needs none.
    /// Never surfaced in snapshots, status payloads, or logs.
    public let adminToken: String?

    /// Creates an endpoint from a base URL.
    /// - Parameters:
    ///   - baseURL: The daemon base URL (scheme + host + port).
    ///   - adminToken: The server's admin token, when it has one.
    public init(baseURL: URL, adminToken: String? = nil) {
        self.baseURL = baseURL
        self.adminToken = adminToken
    }

    /// Parses a user-configured endpoint string.
    ///
    /// Accepts a full URL (`http://127.0.0.1:31415`) or a bare `host:port` /
    /// `host` (scheme defaults to `http`). Returns `nil` for empty or
    /// unparsable input so callers can fall back to ``standard``.
    ///
    /// - Parameter configurationString: The raw setting value.
    public init?(configurationString: String) {
        let trimmed = configurationString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil,
              // The integration is token-free and the endpoint string is
              // echoed by `subrouter.status` and CLI JSON output; embedded
              // user:password credentials must never ride along.
              url.user() == nil,
              url.password() == nil else {
            return nil
        }
        self.baseURL = url
        self.adminToken = nil
    }

    /// Resolves a daemon path (e.g. `"/_subrouter/health"`) against the base.
    /// - Parameter path: The absolute path to resolve.
    /// - Returns: The full request URL.
    public func url(forPath path: String) -> URL {
        baseURL.appending(path: path)
    }
}
