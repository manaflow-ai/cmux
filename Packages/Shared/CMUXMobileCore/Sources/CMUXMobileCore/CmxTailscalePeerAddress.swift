import Darwin
import Foundation

/// A canonical numeric address assigned to one Tailscale peer.
///
/// Construction rejects generic CGNAT, public, private-LAN, and Tailscale
/// service addresses. Callers can therefore persist ``value`` as a transport
/// target without retaining a DNS dependency.
public struct CmxTailscalePeerAddress: Hashable, Sendable {
    /// The address family used by this peer address.
    public enum Family: Hashable, Sendable {
        /// A peer address in Tailscale's `100.64.0.0/10` range.
        case ipv4
        /// A peer address in Tailscale's `fd7a:115c:a1e0::/48` range.
        case ipv6
    }

    /// The canonical numeric spelling suitable for a host/port endpoint.
    public let value: String
    /// The numeric address family.
    public let family: Family
    let bytes: [UInt8]

    /// Parses one numeric Tailscale peer address.
    /// - Parameter rawValue: An IPv4 or IPv6 literal without brackets or a zone.
    public init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value == rawValue else { return nil }

        if let parsed = Self.parseIPv4(value), Self.isTailscaleIPv4Peer(parsed.bytes) {
            self.value = parsed.canonical
            family = .ipv4
            bytes = parsed.bytes
            return
        }
        if let parsed = Self.parseIPv6(value), Self.isTailscaleIPv6Peer(parsed.bytes) {
            self.value = parsed.canonical
            family = .ipv6
            bytes = parsed.bytes
            return
        }
        return nil
    }

    private static func parseIPv4(_ value: String) -> (canonical: String, bytes: [UInt8])? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return (decode(buffer), bytes)
    }

    private static func parseIPv6(_ value: String) -> (canonical: String, bytes: [UInt8])? {
        guard !value.contains("%") else { return nil }
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return (decode(buffer).lowercased(), bytes)
    }

    private static func decode(_ buffer: [CChar]) -> String {
        String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    private static func isTailscaleIPv4Peer(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4,
              bytes[0] == 100,
              (bytes[1] & 0xC0) == 64 else {
            return false
        }
        // Tailscale reserves these ranges for local services and test traffic;
        // they do not identify a peer node.
        if bytes[1] == 100, bytes[2] == 0 || bytes[2] == 100 {
            return false
        }
        if bytes[1] == 115, bytes[2] == 92 || bytes[2] == 93 {
            return false
        }
        return true
    }

    private static func isTailscaleIPv6Peer(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16,
              bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) else {
            return false
        }
        // `fd7a:115c:a1e0::53` is the local MagicDNS service, not a peer.
        let magicDNS = [UInt8](repeating: 0, count: 9) + [0x53]
        return Array(bytes[6...]) != magicDNS
    }
}
