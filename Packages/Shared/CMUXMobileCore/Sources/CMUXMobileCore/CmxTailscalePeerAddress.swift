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
        guard let literal = CmxIPLiteral(value, family: .ipv4), let canonical = literal.canonicalText else { return nil }
        // Darwin's inet_pton accepts leading-zero octets as decimal while the
        // dialer's inet_aton reads them as octal. Refuse any non-canonical
        // spelling so classification never diverges from dialing.
        guard canonical == value else { return nil }
        return (canonical, literal.bytes)
    }

    private static func parseIPv6(_ value: String) -> (canonical: String, bytes: [UInt8])? {
        guard !value.contains("%") else { return nil }
        guard let literal = CmxIPLiteral(value, family: .ipv6), let canonical = literal.canonicalText else { return nil }
        return (canonical.lowercased(), literal.bytes)
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
        return Array(bytes.dropFirst(6)) != magicDNS
    }
}
