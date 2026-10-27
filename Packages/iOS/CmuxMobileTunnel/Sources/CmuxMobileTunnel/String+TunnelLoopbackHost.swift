#if canImport(Network)
import Network
#elseif canImport(Glibc)
import Glibc
#endif

/// Destinations that mean "the exit machine itself": `localhost`,
/// `*.localhost` (RFC 6761), `127.0.0.0/8`, `::1`, and the unspecified
/// addresses browsers treat as local.
extension String {
    /// Whether this destination host means the exit machine itself.
    public var isTunnelLoopbackHost: Bool {
        var host = lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "0.0.0.0" || host == "::" { return true }
        if let isLoopback = host.ipv6IsLoopback { return isLoopback }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    /// For an IPv6 literal, whether it is `::1` or an IPv4-mapped loopback
    /// address; nil when this is not an IPv6 literal.
    private var ipv6IsLoopback: Bool? {
        #if canImport(Network)
        guard let v6 = IPv6Address(self) else { return nil }
        if v6 == .loopback { return true }
        if let mapped = v6.asIPv4 { return mapped.isLoopback }
        return false
        #else
        var bytes = [UInt8](repeating: 0, count: 16)
        // SAFETY: inet_pton writes sizeof(struct in6_addr) (16) bytes for AF_INET6,
        // exactly bytes.count. It reads the NUL-terminated copy of `self` Swift
        // passes, which lives for this call.
        guard unsafe inet_pton(AF_INET6, self, &bytes) == 1 else { return nil }
        if bytes == Array(repeating: 0, count: 15) + [1] { return true }
        // ::ffff:a.b.c.d carries an IPv4 address; 127.0.0.0/8 is loopback.
        if bytes.prefix(12) == Array(repeating: 0, count: 10) + [0xFF, 0xFF] { return bytes.dropFirst(12).first == 127 }
        return false
        #endif
    }
}
