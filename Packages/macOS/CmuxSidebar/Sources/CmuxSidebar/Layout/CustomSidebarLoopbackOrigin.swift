public import Foundation

/// An `http`/`https` origin whose host is a literal loopback address.
///
/// A web sidebar earns the focus bridge only when it is served by something already running on this
/// machine, and the only thing that proves that at the origin level is a literal loopback address.
/// `localhost` does not: it is a name, and a name resolves through whatever the host file, the
/// resolver, or a hostile DHCP lease says it resolves to. So the check is on the address literal
/// itself, never on a name that might mean loopback today.
public struct CustomSidebarLoopbackOrigin: Equatable, Sendable {
    /// Lowercased scheme, always `http` or `https`.
    public let scheme: String
    /// The literal loopback host, lowercased and without IPv6 brackets (`127.0.0.1`, `::1`).
    public let host: String
    /// The effective port: the URL's port, or the scheme's default when none was given.
    public let port: Int

    /// Reads the origin out of a URL, returning `nil` unless every part qualifies.
    public init?(url: URL) {
        self.init(scheme: url.scheme, host: url.host, port: url.port)
    }

    /// Builds an origin from already-separated parts, as WebKit reports them for a frame.
    ///
    /// - Parameters:
    ///   - scheme: The scheme; anything other than `http`/`https` disqualifies.
    ///   - host: The host; must be a literal loopback address.
    ///   - port: The port, or `nil`/`0` to mean the scheme's default (WebKit reports `0` for a
    ///     default port).
    public init?(scheme: String?, host: String?, port: Int?) {
        guard let rawScheme = scheme?.lowercased(),
              rawScheme == "http" || rawScheme == "https"
        else { return nil }
        guard let rawHost = host.map(Self.normalizedHost), Self.isLoopbackLiteral(rawHost) else {
            return nil
        }
        self.scheme = rawScheme
        self.host = rawHost
        if let port, port != 0 {
            self.port = port
        } else {
            self.port = rawScheme == "https" ? 443 : 80
        }
    }

    /// Whether a URL names this exact origin (scheme, host, and effective port all equal).
    ///
    /// Path and query are deliberately unconstrained: a page is allowed to route within itself, and
    /// the same server answering on the same port is the trust boundary the arming established.
    public func matches(url: URL) -> Bool {
        guard let other = CustomSidebarLoopbackOrigin(url: url) else { return false }
        return other == self
    }

    /// Strips IPv6 brackets and lowercases, so `[::1]` and `::1` compare equal.
    private static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Whether a host is a literal loopback address: IPv4 in `127.0.0.0/8`, or IPv6 `::1`.
    ///
    /// Deliberately strict. Only a full dotted quad counts, so the shorthand forms a resolver would
    /// happily accept (`127.1`, `0x7f.1`, `2130706433`) are rejected rather than reasoned about.
    private static func isLoopbackLiteral(_ host: String) -> Bool {
        if host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        var values: [Int] = []
        for octet in octets {
            guard !octet.isEmpty, octet.count <= 3, octet.allSatisfy(\.isNumber),
                  let value = Int(octet), value >= 0, value <= 255
            else { return false }
            values.append(value)
        }
        return values[0] == 127
    }
}
