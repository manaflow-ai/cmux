import Darwin
import Foundation

/// Single source of truth for "is this host loopback?" across the mobile
/// stack.
///
/// Pairing policy depends on this answer in two opposite directions, so it
/// must come from one place:
/// - Loopback is the *most* trusted channel for manual dev pairing (it never
///   leaves the machine, so it may carry the Stack bearer token).
/// - Loopback is *forbidden* in anything that arrives by QR or deep link: a
///   scanned code pointing at `127.0.0.1` would make the phone dial itself,
///   so the phone rejects it outright and the Mac never mints one.
///
/// Because this is a trust boundary, classification is byte-based, not
/// string-pattern-based: hosts are parsed with the same libc semantics the
/// dialer's resolver applies (`inet_aton` for IPv4 names, so legacy spellings
/// like `127.1`, `0x7f.0.0.1`, and `2130706433` classify exactly as they
/// dial; `inet_pton` for IPv6, so every compressed/uncompressed/mixed
/// spelling of one address classifies identically). Anything that dials the
/// local machine counts: `127.0.0.0/8`, the unspecified `0.0.0.0/8` (a TCP
/// connect to it lands on loopback), IPv6 `::1` and `::`, and IPv4-mapped or
/// IPv4-compatible IPv6 forms embedding those ranges. `localhost` and
/// `*.localhost` names match with or without the trailing root dot.
public struct CmxLoopbackHost: Sendable {
    /// Creates the classifier. It is stateless: construct one inline wherever
    /// a loopback decision is needed; every instance applies the same rules.
    public init() {}

    /// Whether `host` names the local machine.
    /// - Parameter host: A bare host string (IPv4, IPv6 with or without
    ///   brackets or a zone index, or a DNS name).
    public func matches(_ host: String) -> Bool {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("["), normalized.hasSuffix("]"), normalized.count > 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }
        // A single trailing root dot is the fully-qualified spelling of the
        // same name (`localhost.`) and must classify identically.
        if normalized.hasSuffix("."), !normalized.dropLast().isEmpty {
            normalized = String(normalized.dropLast())
        }
        guard !normalized.isEmpty else {
            return false
        }
        if normalized == "localhost" || normalized.hasSuffix(".localhost") {
            return true
        }
        if let firstIPv4Octet = ipv4FirstOctet(normalized) {
            return isSelfDialingIPv4FirstOctet(firstIPv4Octet)
        }
        if let ipv6 = ipv6Bytes(normalized) {
            return isSelfDialingIPv6(ipv6)
        }
        return false
    }

    /// Whether `endpoint` dials a loopback host.
    /// - Parameter endpoint: The attach endpoint to classify.
    public func matches(_ endpoint: CmxAttachEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else {
            return false
        }
        return matches(host)
    }

    /// Whether `route` is a loopback route: either declared as the
    /// `debugLoopback` transport kind or dialing a loopback host.
    /// - Parameter route: The attach route to classify.
    public func matches(_ route: CmxAttachRoute) -> Bool {
        route.kind == .debugLoopback || matches(route.endpoint)
    }
}

private extension CmxLoopbackHost {
    /// The first octet of `host` parsed with `inet_aton` semantics (the same
    /// numeric forms the resolver accepts for name-looking hosts: dotted
    /// quad, fewer-than-four parts, octal, hex, and single 32-bit decimals),
    /// or `nil` when the host is not an IPv4 literal in any of those forms.
    func ipv4FirstOctet(_ host: String) -> UInt8? {
        var address = in_addr()
        guard inet_aton(host, &address) != 0 else {
            return nil
        }
        // `s_addr` is in network byte order; the first octet is the
        // highest-order byte of the big-endian value.
        return UInt8(truncatingIfNeeded: UInt32(bigEndian: address.s_addr) >> 24)
    }

    /// `127.0.0.0/8` is loopback; `0.0.0.0/8` (the unspecified range) is
    /// included because a TCP connect to it lands on the local machine too.
    func isSelfDialingIPv4FirstOctet(_ firstOctet: UInt8) -> Bool {
        firstOctet == 127 || firstOctet == 0
    }

    /// The 16 address bytes of `host` parsed with `inet_pton`, or `nil` when
    /// it is not an IPv6 literal. A zone index suffix (`%lo0`) is stripped
    /// first: the zone scopes which interface dials, not which address.
    func ipv6Bytes(_ host: String) -> [UInt8]? {
        var literal = host
        if let zoneSeparator = literal.firstIndex(of: "%") {
            literal = String(literal[..<zoneSeparator])
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, literal, &address) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    /// Whether the 16 IPv6 address bytes name the local machine (`::1`, `::`,
    /// or an IPv4-mapped/IPv4-compatible form embedding a self-dialing range).
    func isSelfDialingIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else {
            return false
        }
        // `::1` (loopback) and `::` (unspecified; connects locally like
        // 0.0.0.0): first 15 bytes zero, last byte 0 or 1.
        if bytes[0..<15].allSatisfy({ $0 == 0 }), bytes[15] <= 1 {
            return true
        }
        // IPv4-mapped (`::ffff:a.b.c.d`) and the deprecated IPv4-compatible
        // (`::a.b.c.d`) forms: classify by the embedded IPv4 first octet.
        let prefixIsZero = bytes[0..<10].allSatisfy { $0 == 0 }
        let isMapped = prefixIsZero && bytes[10] == 0xFF && bytes[11] == 0xFF
        let isCompatible = prefixIsZero && bytes[10] == 0 && bytes[11] == 0
        if isMapped || isCompatible {
            return isSelfDialingIPv4FirstOctet(bytes[12])
        }
        return false
    }
}
