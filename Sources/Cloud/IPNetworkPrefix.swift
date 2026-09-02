import Foundation

/// One IPv4 or IPv6 network in CIDR notation (`10.0.0.0/8`, `fd00::/8`), with
/// membership tests for literal addresses.
///
/// Cloud VMs on a private network are addressed by literal IPs inside the
/// owner's WireGuard `AllowedIPs`; this is the pure address arithmetic behind
/// "does this route need the tunnel".
struct IPNetworkPrefix: Sendable, Equatable {
    /// The network's family, fixing the address width.
    enum Family: Sendable, Equatable {
        case v4
        case v6
    }

    let family: Family
    /// Network bytes with host bits already cleared (4 or 16 bytes).
    let network: [UInt8]
    let prefixLength: Int

    /// Parses `address/prefix`; a bare address is a host route (`/32` or `/128`).
    init?(cidr: String) {
        let trimmed = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
        guard let addressText = parts.first, let address = Self.bytes(of: addressText) else { return nil }
        let bits = address.count * 8
        let prefix: Int
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), (0...bits).contains(parsed) else { return nil }
            prefix = parsed
        } else {
            prefix = bits
        }
        family = address.count == 4 ? .v4 : .v6
        prefixLength = prefix
        network = Self.masked(address, prefixLength: prefix)
    }

    /// Whether the literal `host` (no brackets, no zone) lies inside this network.
    func contains(_ host: String) -> Bool {
        guard let address = Self.bytes(of: host) else { return false }
        guard address.count == network.count else { return false }
        return Self.masked(address, prefixLength: prefixLength) == network
    }

    /// The RFC 1918 and RFC 4193 private ranges: addresses that are never
    /// reachable on the public Internet and therefore only make sense through a
    /// private network such as the owner's Cloud VM VPC.
    static let privateRanges: [IPNetworkPrefix] = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7",
    ].compactMap(IPNetworkPrefix.init(cidr:))

    /// Whether `host` is a literal private-range IP address.
    static func isPrivateAddress(_ host: String) -> Bool {
        privateRanges.contains { $0.contains(host) }
    }

    /// Whether `host` is a literal address inside any of `cidrs` (unparseable
    /// entries are ignored).
    static func host(_ host: String, isWithinAnyOf cidrs: [String]) -> Bool {
        cidrs.compactMap(IPNetworkPrefix.init(cidr:)).contains { $0.contains(host) }
    }

    /// The host of a URL route with IPv6 brackets stripped, or nil when the route
    /// has no host.
    static func routeHost(_ route: String) -> String? {
        guard let components = URLComponents(string: route), var host = components.host, !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }

    private static func bytes(of address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    private static func masked(_ address: [UInt8], prefixLength: Int) -> [UInt8] {
        var out = address
        for index in out.indices {
            let bitsForByte = max(0, min(8, prefixLength - index * 8))
            let mask: UInt8 = bitsForByte == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - bitsForByte))
            out[index] &= mask
        }
        return out
    }
}
