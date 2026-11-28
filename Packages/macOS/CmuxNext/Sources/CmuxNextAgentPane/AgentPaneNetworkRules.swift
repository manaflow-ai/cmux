import Darwin
import Foundation

/// The addresses a host fetch for reply content may reach (decision D5; security bar 4.3 item 1
/// of the markdown parity audit). Reply text is untrusted, so a fetch must never reach this Mac,
/// the local network, the tailnet or any address that is not on the public internet: loopback,
/// RFC 1918, link-local, CGNAT and Tailscale (100.64.0.0/10), unique local, multicast,
/// unspecified, documentation and benchmark ranges. An IPv6 address that embeds an IPv4 one
/// (mapped, NAT64, 6to4) is judged by the IPv4 address.
nonisolated struct AgentPaneNetworkRules {
    /// Whether `address` (an IPv4 or IPv6 literal) is public.
    static func isPublic(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return isPublic(v4: Array(withUnsafeBytes(of: &v4.s_addr) { Array($0) })) }
        var v6 = in6_addr()
        // A scoped literal (`fe80::1%en0`) is never public.
        guard !address.contains("%"), inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        return isPublic(v6: withUnsafeBytes(of: &v6) { Array($0) })
    }

    static func isPublic(v4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let (a, b, c) = (bytes[0], bytes[1], bytes[2])
        switch a {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(b): return false // CGNAT, Tailscale
        case 169 where b == 254: return false
        case 172 where (16...31).contains(b): return false
        case 192 where b == 168: return false
        case 192 where b == 0 && (c == 0 || c == 2): return false // IETF, TEST-NET-1
        case 198 where b == 18 || b == 19: return false // benchmarking
        case 198 where b == 51 && c == 100: return false // TEST-NET-2
        case 203 where b == 0 && c == 113: return false // TEST-NET-3
        case 224...255: return false // multicast, reserved, broadcast
        default: return true
        }
    }

    static func isPublic(v6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible, deprecated): the IPv4 address.
        if bytes[0..<10].allSatisfy({ $0 == 0 }) {
            if bytes[10] == 0xff && bytes[11] == 0xff { return isPublic(v4: Array(bytes[12..<16])) }
            if bytes[10] == 0 && bytes[11] == 0 { return false } // ::, ::1, ::a.b.c.d
            return false
        }
        // 64:ff9b::/96 (NAT64): the embedded IPv4 address.
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b && bytes[4..<12].allSatisfy({ $0 == 0 }) {
            return isPublic(v4: Array(bytes[12..<16]))
        }
        // 2002::/16 (6to4): the IPv4 address in bits 16 to 47.
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return isPublic(v4: Array(bytes[2..<6])) }
        if bytes[0] & 0xfe == 0xfc { return false } // fc00::/7 unique local (Tailscale fd7a:115c:a1e0::/48)
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return false } // fe80::/10 link-local
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0xc0 { return false } // fec0::/10 site-local
        if bytes[0] == 0xff { return false } // multicast
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return false } // documentation
        if bytes[0] == 0x01 && bytes[1] == 0x00 && bytes[2..<8].allSatisfy({ $0 == 0 }) { return false } // 100::/64 discard
        // Global unicast is 2000::/3; nothing else is routed on the internet.
        return bytes[0] & 0xe0 == 0x20
    }

    /// Every address `host` resolves to, nil when it does not resolve. Runs `getaddrinfo` off
    /// the caller's thread.
    @concurrent static func addresses(of host: String) async -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let address = entry.pointee.ai_addr { addresses.append(literal(address)) }
            cursor = entry.pointee.ai_next
        }
        return addresses.isEmpty ? nil : addresses
    }

    /// Whether `host` resolves and every address it resolves to is public. An IP literal is
    /// judged as written.
    static func resolvesPublicly(_ host: String) async -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard !bare.isEmpty, let addresses = await addresses(of: bare) else { return false }
        return addresses.allSatisfy(isPublic)
    }

    private static func literal(_ address: UnsafeMutablePointer<sockaddr>) -> String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_family == sa_family_t(AF_INET6) ? MemoryLayout<sockaddr_in6>.size
                                                                                   : MemoryLayout<sockaddr_in>.size)
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
