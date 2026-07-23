public import Foundation

/// The base address of a subrouter daemon.
///
/// Defaults to the daemon's standard loopback bind, `http://127.0.0.1:31415`.
/// Loopback requests are trusted by the daemon (no token needed), which is
/// the only deployment cmux drives.
public struct SubrouterEndpoint: Sendable, Hashable {
    /// The standard daemon address, `http://127.0.0.1:31415`.
    public static let standard = SubrouterEndpoint(
        baseURL: URL(string: "http://127.0.0.1:31415")!
    )

    /// The base URL requests are resolved against.
    public let baseURL: URL

    /// Creates an endpoint from a base URL.
    /// - Parameter baseURL: The daemon base URL (scheme + host + port).
    public init(baseURL: URL) {
        self.baseURL = baseURL
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
    }

    /// Resolves a daemon path (e.g. `"/_subrouter/health"`) against the base.
    /// - Parameter path: The absolute path to resolve.
    /// - Returns: The full request URL.
    public func url(forPath path: String) -> URL {
        baseURL.appending(path: path)
    }
}
