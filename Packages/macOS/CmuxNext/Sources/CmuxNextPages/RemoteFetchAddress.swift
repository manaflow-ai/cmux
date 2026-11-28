import Darwin
import Foundation

/// An IPv4 or IPv6 address as bytes, classified by range for a host fetch of page content.
///
/// The URL is untrusted page or reply text, so a fetch must never reach this Mac, the local
/// network, the tailnet or any address that is not on the public internet: loopback, RFC 1918,
/// link-local, CGNAT and Tailscale (100.64.0.0/10), unique local, site-local, multicast,
/// unspecified, documentation, benchmark and discard ranges. An IPv6 address that embeds an IPv4
/// one (mapped, NAT64, 6to4) is judged by the IPv4 address. This is the one copy of the rule:
/// the markdown remote images and the agent pane's reply images and media both use it.
public nonisolated enum RemoteAddress: Hashable, Sendable {
    case v4([UInt8])
    case v6([UInt8])

    /// A dotted IPv4 or an IPv6 literal (no brackets, no zone); nil for a name.
    public init?(literal: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            self = .v4(withUnsafeBytes(of: &v4) { Array($0) })
            return
        }
        var v6 = in6_addr()
        if !literal.contains("%"), inet_pton(AF_INET6, literal, &v6) == 1 {
            self = .v6(withUnsafeBytes(of: &v6) { Array($0) })
            return
        }
        return nil
    }

    /// Whether a fetch may connect to this address.
    public var isPublic: Bool {
        switch self {
        case .v4(let bytes): Self.isPublic(v4: bytes)
        case .v6(let bytes): Self.isPublic(v6: bytes)
        }
    }

    private static func isPublic(v4 bytes: [UInt8]) -> Bool {
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

    private static func isPublic(v6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        // ::ffff:a.b.c.d (mapped): the IPv4 address. ::, ::1 and ::a.b.c.d (compatible): never.
        if bytes[0..<10].allSatisfy({ $0 == 0 }) {
            if bytes[10] == 0xff && bytes[11] == 0xff { return isPublic(v4: Array(bytes[12..<16])) }
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
}

/// Resolves a host name to addresses: the fetch's one lookup. The app's is getaddrinfo; a test
/// may answer for itself.
public protocol RemoteAddressResolving: Sendable {
    func resolve(_ host: String) async throws -> [RemoteAddress]
}

/// getaddrinfo off the caller's actor.
public nonisolated struct SystemRemoteResolver: RemoteAddressResolving {
    public init() {}

    public func resolve(_ host: String) async throws -> [RemoteAddress] {
        try await Self.lookup(host)
    }

    @concurrent private static func lookup(_ host: String) async throws -> [RemoteAddress] {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { throw URLError(.cannotFindHost) }
        defer { freeaddrinfo(first) }
        var addresses: [RemoteAddress] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let entry = node {
            if let raw = entry.pointee.ai_addr {
                switch Int32(raw.pointee.sa_family) {
                case AF_INET:
                    raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                        var address = pointer.pointee.sin_addr
                        addresses.append(.v4(withUnsafeBytes(of: &address) { Array($0) }))
                    }
                case AF_INET6:
                    raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        var address = pointer.pointee.sin6_addr
                        addresses.append(.v6(withUnsafeBytes(of: &address) { Array($0) }))
                    }
                default:
                    break
                }
            }
            node = entry.pointee.ai_next
        }
        var seen: Set<RemoteAddress> = []
        return addresses.filter { seen.insert($0).inserted }
    }
}
