import Darwin
import Foundation

/// Classifies host names and numeric addresses for outbound network policy.
public struct NetworkAddressPolicy: Sendable {
    /// Creates a stateless network-address policy.
    public init() {}

    /// Returns whether a host name or literal is eligible for public-network access.
    ///
    /// This rejects local-only names and numeric address ranges that must never be
    /// contacted by features consuming untrusted URLs.
    ///
    /// - Parameter rawHost: A DNS name, IPv4 literal, or IPv6 literal.
    /// - Returns: `true` when the host is not intrinsically local or reserved.
    public func allowsPublicInternetHost(_ rawHost: String) -> Bool {
        let host = normalizedHost(rawHost)
        guard !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              host != "local",
              !host.hasSuffix(".local") else {
            return false
        }
        if let address = ipv4Address(host) {
            return allowsPublicIPv4Address(ipv4Bytes(address))
        }
        if let address = ipv6Address(host) {
            return allowsPublicIPv6Address(ipv6Bytes(address))
        }
        return true
    }

    /// Returns whether four network-order IPv4 bytes identify a public address.
    ///
    /// - Parameter bytes: Four IPv4 bytes in network order.
    /// - Returns: `false` for private, loopback, link-local, documentation,
    ///   benchmarking, multicast, and reserved ranges.
    public func allowsPublicIPv4Address(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        let third = bytes[2]
        if first == 0 || first == 10 || first == 127 { return false }
        if first == 100, (64...127).contains(second) { return false }
        if first == 169, second == 254 { return false }
        if first == 172, (16...31).contains(second) { return false }
        if first == 192, second == 0, third == 0 || third == 2 { return false }
        if first == 192, second == 168 { return false }
        if first == 198, (18...19).contains(second) { return false }
        if first == 198, second == 51, third == 100 { return false }
        if first == 203, second == 0, third == 113 { return false }
        if first >= 224 { return false }
        return true
    }

    /// Returns whether sixteen network-order IPv6 bytes identify a public address.
    ///
    /// - Parameter bytes: Sixteen IPv6 bytes in network order.
    /// - Returns: `false` for unspecified, loopback, local, multicast, mapped
    ///   private, and non-global-unicast ranges.
    public func allowsPublicIPv6Address(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }), bytes[15] == 1 { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return allowsPublicIPv4Address(Array(bytes[12..<16]))
        }
        // Public Internet IPv6 destinations are global-unicast (2000::/3).
        return bytes[0] & 0xE0 == 0x20
    }

    /// Normalizes brackets, surrounding whitespace, case, and a trailing DNS dot.
    ///
    /// - Parameter rawHost: A host name or literal.
    /// - Returns: The normalized host spelling.
    public func normalizedHost(_ rawHost: String) -> String {
        rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]").union(.whitespacesAndNewlines))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func ipv4Address(_ host: String) -> in_addr? {
        var address = in_addr()
        guard host.withCString({ Darwin.inet_aton($0, &address) }) != 0 else { return nil }
        return address
    }

    private func ipv6Address(_ host: String) -> in6_addr? {
        var address = in6_addr()
        guard host.withCString({ Darwin.inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return address
    }

    private func ipv4Bytes(_ address: in_addr) -> [UInt8] {
        Array(withUnsafeBytes(of: address.s_addr) { $0 })
    }

    private func ipv6Bytes(_ address: in6_addr) -> [UInt8] {
        Array(withUnsafeBytes(of: address) { $0 })
    }
}
