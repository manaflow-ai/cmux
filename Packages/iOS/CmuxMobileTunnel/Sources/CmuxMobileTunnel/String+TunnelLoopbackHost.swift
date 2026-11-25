import Foundation
#if canImport(Network)
import Network
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
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
        #if canImport(Network)
        if let v6 = IPv6Address(host) {
            if v6 == .loopback { return true }
            if let mapped = v6.asIPv4 { return mapped.isLoopback }
            return false
        }
        #else
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes == [UInt8](repeating: 0, count: 15) + [1] { return true }
            // IPv4-mapped (::ffff:a.b.c.d): loopback when the IPv4 part is 127/8.
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return bytes[12] == 127 }
            return false
        }
        #endif
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
