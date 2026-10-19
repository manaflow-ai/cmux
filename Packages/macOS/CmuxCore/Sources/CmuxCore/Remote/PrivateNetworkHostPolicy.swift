import Darwin
import Foundation

/// Classifies URL hosts that a remote machine could use to reach this Mac or
/// its local network.
///
/// The checks are static: a public DNS name can still resolve to a private
/// address, which ``requiresAddressLookup(host:)`` reports.
public struct PrivateNetworkHostPolicy: Sendable {
    private static let localNameSuffixes = [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".localdomain"]
    private static let numericIPv4Characters = Set("0123456789abcdefx.")

    /// Creates the policy.
    public init() {}

    /// Whether `host` names a loopback, link-local, private or otherwise
    /// non-public destination.
    ///
    /// Hosts that cannot be classified, such as empty, malformed or
    /// non-ASCII hosts, count as non-public.
    public func isNonPublic(host: String) -> Bool {
        switch classify(host) {
        case .invalid:
            return true
        case .ipv4(let address):
            return !isPublic(ipv4: address)
        case .ipv6(let bytes):
            return !isPublic(ipv6: bytes)
        case .name(let name):
            return isLocalName(name)
        }
    }

    /// Whether `host` names this machine's loopback interface.
    public func isLoopback(host: String) -> Bool {
        switch classify(host) {
        case .invalid:
            return false
        case .ipv4(let address):
            return address >> 24 == 127 || address == 0
        case .ipv6(let bytes):
            if let embedded = mappedIPv4(bytes) {
                return embedded >> 24 == 127 || embedded == 0
            }
            return bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] <= 1
        case .name(let name):
            return name == "localhost" || name.hasSuffix(".localhost") || RemoteLoopbackProxyAlias.isLoopbackHost(name)
        }
    }

    /// Whether `host` is a DNS name whose addresses must be checked before a
    /// remote-initiated open.
    public func requiresAddressLookup(host: String) -> Bool {
        guard case .name(let name) = classify(host) else { return false }
        return !isLocalName(name)
    }

    private enum HostKind {
        case invalid
        case ipv4(UInt32)
        case ipv6([UInt8])
        case name(String)
    }

    private func classify(_ raw: String) -> HostKind {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.contains(":") {
            if let zone = host.firstIndex(of: "%") {
                host = String(host[..<zone])
            }
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return .invalid }
            return .ipv6(withUnsafeBytes(of: &address) { Array($0) })
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        host = host.lowercased()
        guard !host.isEmpty, host.allSatisfy(\.isASCII), !host.contains("%") else { return .invalid }
        let lastLabel = host.split(separator: ".").last.map(String.init) ?? host
        let isNumeric = lastLabel.allSatisfy(\.isNumber)
            || (lastLabel.hasPrefix("0x") && lastLabel.dropFirst(2).allSatisfy(\.isHexDigit))
        guard isNumeric else { return .name(host) }
        // A numeric last label makes the host an IPv4 address in URL parsing,
        // including the legacy decimal, octal, hex and short forms.
        guard host.allSatisfy({ Self.numericIPv4Characters.contains($0) }) else { return .invalid }
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else { return .invalid }
        return .ipv4(UInt32(bigEndian: address.s_addr))
    }

    private func isLocalName(_ name: String) -> Bool {
        if name == "localhost" || !name.contains(".") { return true }
        if Self.localNameSuffixes.contains { name.hasSuffix($0) } { return true }
        let alias = RemoteLoopbackProxyAlias.aliasHost
        return name == alias || name.hasSuffix("." + alias)
    }

    private func isPublic(ipv4 address: UInt32) -> Bool {
        let nonPublic: [(network: UInt32, prefix: UInt32)] = [
            (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8),
            (0xA9FE_0000, 16), (0xAC10_0000, 12), (0xC000_0000, 24), (0xC000_0200, 24),
            (0xC0A8_0000, 16), (0xC612_0000, 15), (0xC633_6400, 24), (0xCB00_7100, 24),
            (0xE000_0000, 4), (0xF000_0000, 4),
        ]
        return !nonPublic.contains { range in
            let mask = UInt32.max << (32 - range.prefix)
            return address & mask == range.network
        }
    }

    private func isPublic(ipv6 bytes: [UInt8]) -> Bool {
        if let embedded = mappedIPv4(bytes) {
            return isPublic(ipv4: embedded)
        }
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            return isPublic(ipv4: ipv4(bytes[2..<6]))
        }
        // Teredo and documentation prefixes.
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00 { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return false }
        return bytes[0] & 0xE0 == 0x20
    }

    /// The IPv4 address inside an IPv4-mapped (`::ffff:0:0/96`) or NAT64
    /// (`64:ff9b::/96`) IPv6 address.
    private func mappedIPv4(_ bytes: [UInt8]) -> UInt32? {
        let isMapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
        let isNAT64 = bytes[0..<4] == [0x00, 0x64, 0xFF, 0x9B] && bytes[4..<12].allSatisfy { $0 == 0 }
        return isMapped || isNAT64 ? ipv4(bytes[12..<16]) : nil
    }

    private func ipv4(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
