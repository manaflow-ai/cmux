import Darwin

/// A numeric IP address in network byte order, parsed by `inet_pton` and
/// printed by `inet_ntop`. Every IP text conversion in the module goes through
/// here, so these two calls are its only pointer use for addresses.
struct CmxIrohIPLiteral: Equatable, Sendable {
    let family: CmxIrohLANSocketAddress.Family
    /// Four bytes for IPv4, sixteen for IPv6, most significant first.
    let bytes: [UInt8]

    /// Parses `text` strictly as `family`: dotted quads or standard IPv6 text,
    /// never `127.1`, a hex quad or a `%scope` suffix.
    init?(_ text: String, family: CmxIrohLANSocketAddress.Family) {
        // Darwin's inet_pton accepts a `%zone` suffix and writes the interface
        // index into a link-local address's bytes (`fe80::1%en0` becomes
        // fe80:7::1). Refuse it here so the parse is strict; a caller that takes a
        // scoped literal (CmxIrohIPAddressScope) strips the zone first.
        guard !text.utf8.contains(UInt8(ascii: "%")) else { return nil }
        var parsed = [UInt8](repeating: 0, count: family == .ipv4 ? 4 : 16) // byteCount(family)
        // SAFETY: inet_pton writes sizeof(struct in_addr) (4) bytes for AF_INET and
        // sizeof(struct in6_addr) (16) for AF_INET6, exactly parsed.count. It reads
        // the NUL-terminated copy of `text` Swift passes, which lives for this call.
        guard unsafe inet_pton(Self.addressFamily(family), text, &parsed) == 1 else { return nil }
        self.family = family
        bytes = parsed
    }

    /// The canonical text `inet_ntop` prints for the address.
    var canonicalText: String? {
        guard bytes.count == Self.byteCount(family) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(clamping: INET6_ADDRSTRLEN))
        // SAFETY: inet_ntop reads 4 (AF_INET) or 16 (AF_INET6) bytes, the count
        // checked above, and writes at most buffer.count bytes, the size passed,
        // NUL included. Both arrays outlive the call.
        guard unsafe inet_ntop(Self.addressFamily(family), bytes, &buffer, socklen_t(clamping: buffer.count)) != nil else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func byteCount(_ family: CmxIrohLANSocketAddress.Family) -> Int {
        switch family {
        case .ipv4: 4
        case .ipv6: 16
        }
    }

    private static func addressFamily(_ family: CmxIrohLANSocketAddress.Family) -> Int32 {
        switch family {
        case .ipv4: AF_INET
        case .ipv6: AF_INET6
        }
    }
}
