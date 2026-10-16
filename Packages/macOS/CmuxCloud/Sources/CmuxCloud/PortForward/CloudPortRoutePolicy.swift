import Foundation

/// Validates Cloud and SSH browser URLs before a route is opened.
///
/// This value type owns the network policy shared by native Cloud and managed
/// SSH projections. It accepts only HTTP(S) URLs whose replacement host is a
/// private network address, or an explicitly permitted remote loopback host.
public struct CloudPortRoutePolicy: Sendable {
    /// Creates the stateless route policy.
    public init() {}

    /// Replaces the URL host with a validated private or loopback address.
    ///
    /// - Parameters:
    ///   - raw: The URL string to validate and rewrite.
    ///   - address: The authenticated machine address that owns the route.
    ///   - allowLoopback: Whether `127.0.0.1` and `::1` are valid owners.
    /// - Returns: A rewritten URL, or `nil` when the scheme, host, or address
    ///   is outside the route policy.
    public func privateURL(_ raw: String, address: String, allowLoopback: Bool = false) -> URL? {
        guard var parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = IPNetworkPrefix.routeHost(Self.route(for: address)),
              !["0.0.0.0", "::"].contains(host)
        else { return nil }
        if ["127.0.0.1", "::1"].contains(host) {
            guard allowLoopback else { return nil }
        } else {
            guard Self.isPrivateNetworkHost(host) else { return nil }
        }
        parts.host = host.contains(":") ? "[\(host)]" : host
        return parts.url
    }

    /// Rewrites an HTTP route to a local authenticated-forward listener.
    ///
    /// - Parameters:
    ///   - remoteURL: The validated remote HTTP URL.
    ///   - localPort: The listener port on this Mac.
    /// - Returns: The loopback URL, or `nil` for non-HTTP or invalid ports.
    public func localURL(rewriting remoteURL: String, toLoopbackPort localPort: UInt16) -> URL? {
        guard localPort > 0,
              var parts = URLComponents(string: remoteURL),
              parts.scheme?.lowercased() == "http"
        else { return nil }
        parts.host = "127.0.0.1"
        parts.port = Int(localPort)
        return parts.url
    }

    private static func route(for address: String) -> String {
        let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        return "http://\(host)"
    }

    private static func isPrivateNetworkHost(_ host: String) -> Bool {
        if IPNetworkPrefix.isPrivateAddress(host) { return true }
        guard host.contains(":") else {
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            return octets.count == 4 && octets[0] == 169 && octets[1] == 254
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count >= 2 else { return false }
        return bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
    }
}
