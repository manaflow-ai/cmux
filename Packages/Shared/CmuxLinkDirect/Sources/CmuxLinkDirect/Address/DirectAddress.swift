import Foundation
import Network

/// A host the user typed: an IPv4 or IPv6 literal or a DNS name.
public struct DirectAddress: Sendable, Hashable, CustomStringConvertible {
    public enum Form: Sendable, Hashable {
        case ipv4
        case ipv6
        case hostname
    }

    /// The address without brackets or zone-less normalization changes.
    public let host: String
    public let form: Form
    public let addressClass: DirectAddressClass

    /// Parses `100.101.102.103`, `[fd7a:115c:a1e0::1]`, `fe80::1%en0`,
    /// `mac.tailnet.ts.net`, `studio.local`. Returns nil for empty input,
    /// schemes, ports, paths or spaces.
    public init?(_ text: String) {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, host.count <= 253 else { return nil }
        if let v4 = IPv4Address(host), !host.contains(":") {
            self.host = host
            form = .ipv4
            addressClass = Self.classify(v4: Array(v4.rawValue))
        } else if host.contains(":") {
            guard let v6 = IPv6Address(host) else { return nil }
            self.host = host
            form = .ipv6
            addressClass = Self.classify(v6: Array(v6.rawValue))
        } else {
            guard Self.isHostname(host) else { return nil }
            let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            self.host = lower
            form = .hostname
            addressClass = Self.classify(hostname: lower)
        }
    }

    public var description: String { form == .ipv6 ? "[\(host)]" : host }

    var nwHost: NWEndpoint.Host { NWEndpoint.Host(host) }

    private static func isHostname(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let trimmed = host.hasSuffix(".") ? labels.dropLast() : labels[...]
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        }
    }

    static func classify(v4 bytes: [UInt8]) -> DirectAddressClass {
        guard bytes.count == 4 else { return .publicNetwork }
        switch (bytes[0], bytes[1]) {
        case (127, _): return .loopback
        case (100, 64...127): return .tailscale
        case (10, _), (172, 16...31), (192, 168), (169, 254): return .privateNetwork
        default: return .publicNetwork
        }
    }

    static func classify(v6 bytes: [UInt8]) -> DirectAddressClass {
        guard bytes.count == 16 else { return .publicNetwork }
        if bytes == Array(repeating: 0, count: 15) + [1] { return .loopback }
        if bytes.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]) { return .tailscale }
        if bytes[0] & 0xfe == 0xfc { return .privateNetwork }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return .privateNetwork }
        // IPv4-mapped (::ffff:a.b.c.d).
        if bytes.prefix(12) == Array(repeating: 0, count: 10) + [0xff, 0xff] {
            return classify(v4: Array(bytes.suffix(4)))
        }
        return .publicNetwork
    }

    static func classify(hostname: String) -> DirectAddressClass {
        if hostname == "localhost" || hostname.hasSuffix(".localhost") { return .loopback }
        if hostname.hasSuffix(".ts.net") { return .tailscale }
        if hostname.hasSuffix(".local") { return .privateNetwork }
        return .publicNetwork
    }
}
