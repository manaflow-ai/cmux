public import Foundation

/// An IPv4 or IPv6 network in CIDR form, as the Cloud Tunnel's addresses and routes use it.
public struct CloudTunnelCIDR: Sendable, Hashable, CustomStringConvertible {
    /// Whether ``address`` is IPv4 or IPv6.
    public enum Family: Sendable, Hashable {
        case ipv4
        case ipv6
    }

    /// The address part, as written (`10.192.0.2`, `fd00::2`).
    public let address: String
    /// The prefix length; a bare address gets the full length (32 or 128).
    public let prefix: Int
    /// The address family.
    public let family: Family

    /// Parses `address/prefix` or a bare address.
    ///
    /// - Throws: ``CloudTunnelConfiguration/ParseError/invalid(_:)`` for anything else.
    public init(parsing text: String) throws {
        let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
        let address = parts.first ?? ""
        let family: Family
        if Self.isIPv4(address) {
            family = .ipv4
        } else if Self.isIPv6(address) {
            family = .ipv6
        } else {
            throw CloudTunnelConfiguration.ParseError.invalid(text)
        }
        let full = family == .ipv4 ? 32 : 128
        let prefix: Int
        if parts.count == 2 {
            guard let value = Int(parts[1]), (0...full).contains(value) else { throw CloudTunnelConfiguration.ParseError.invalid(text) }
            prefix = value
        } else {
            prefix = full
        }
        self.address = address
        self.prefix = prefix
        self.family = family
    }

    /// The dotted IPv4 subnet mask for ``prefix`` (`255.255.240.0` for 20); `nil` for IPv6.
    public var ipv4Mask: String? {
        guard family == .ipv4 else { return nil }
        let bits: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        return [24, 16, 8, 0].map { String((bits >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }

    /// Whether this is a default route (`0.0.0.0/0` or `::/0`).
    public var isDefaultRoute: Bool { prefix == 0 }

    public var description: String { "\(address)/\(prefix)" }

    private static func isIPv4(_ text: String) -> Bool {
        var storage = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &storage) } == 1
    }

    private static func isIPv6(_ text: String) -> Bool {
        var storage = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &storage) } == 1
    }
}
