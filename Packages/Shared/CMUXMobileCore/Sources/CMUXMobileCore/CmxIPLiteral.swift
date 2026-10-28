#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A numeric IP address in network byte order, parsed by `inet_pton` (or
/// `inet_aton`) and printed by `inet_ntop`. Every IP text conversion in the
/// module goes through here, so these three calls are its only pointer use for
/// addresses (Chromium keeps the same split: net::IPAddress holds the bytes and
/// net/base/ip_address.cc does the text conversion in one place).
struct CmxIPLiteral: Equatable, Sendable {
    enum Family: Equatable, Sendable {
        case ipv4
        case ipv6
    }

    let family: Family
    /// Four bytes for IPv4, sixteen for IPv6, most significant first.
    let bytes: [UInt8]

    /// Parses `text` strictly as `family` with `inet_pton`: a dotted quad for
    /// IPv4, standard IPv6 text (never `127.1`, a hex quad or a `%scope`
    /// suffix); nil for anything else.
    init?(_ text: String, family: Family) {
        var parsed = [UInt8](repeating: 0, count: family.byteCount)
        // SAFETY: inet_pton writes sizeof(struct in_addr) (4) bytes for AF_INET and
        // sizeof(struct in6_addr) (16) for AF_INET6, exactly parsed.count. It reads
        // the NUL-terminated copy of `text` Swift passes, which lives for this call.
        guard unsafe inet_pton(family.addressFamily, text, &parsed) == 1 else { return nil }
        self.family = family
        bytes = parsed
    }

    /// Parses `text` as IPv4 with `inet_aton`, which also accepts the legacy
    /// forms a resolver dials for a name-looking host: fewer than four parts,
    /// octal, hex and a single 32-bit number. Nil when it is none of them.
    init?(resolverIPv4 text: String) {
        var address = in_addr()
        // SAFETY: inet_aton writes one struct in_addr into `address`, a local of that
        // type, and reads the NUL-terminated copy of `text` Swift makes for this call.
        guard unsafe inet_aton(text, &address) != 0 else { return nil }
        // `s_addr` is in network byte order: its big-endian value's top byte is the first octet.
        let value = UInt32(bigEndian: address.s_addr)
        family = .ipv4
        bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    /// The canonical text `inet_ntop` prints for the address; nil only if
    /// `inet_ntop` refuses it.
    var canonicalText: String? {
        var buffer = [CChar](repeating: 0, count: Int(clamping: INET6_ADDRSTRLEN))
        // SAFETY: inet_ntop reads 4 (AF_INET) or 16 (AF_INET6) bytes from `bytes`;
        // both initializers store exactly family.byteCount bytes. It writes at most
        // buffer.count bytes, the size passed, NUL included. Both arrays outlive the call.
        guard unsafe inet_ntop(family.addressFamily, bytes, &buffer, socklen_t(clamping: buffer.count)) != nil else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private extension CmxIPLiteral.Family {
    var byteCount: Int {
        switch self {
        case .ipv4: 4
        case .ipv6: 16
        }
    }

    var addressFamily: Int32 {
        switch self {
        case .ipv4: AF_INET
        case .ipv6: AF_INET6
        }
    }
}
