import Darwin
import Foundation

/// Which link-preview URLs Home may fetch: http(s) to a public host only. No
/// localhost, `.local` or other private names, and every address the name
/// resolves to must be public (no loopback, private, link-local, CGNAT and
/// Tailscale 100.64/10, ULA, multicast or reserved ranges; IPv4-mapped and
/// NAT64 IPv6 are checked as their IPv4 address). A link in a chat must not
/// make the Mac request a service on its own network.
///
/// Limit: LinkPresentation resolves the name again and follows redirects
/// itself, so a DNS rebinding or a redirect to a private address after this
/// check is not caught (README, Link previews).
enum LinkPreviewAddressPolicy {
    private static let privateSuffixes = [".local", ".localhost", ".internal", ".lan", ".home.arpa", ".intranet", ".corp", ".ts.net"]

    /// The URL's form: scheme, host name and any IP literal.
    static func allowsURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.user == nil, url.password == nil,
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || privateSuffixes.contains(where: { host.hasSuffix($0) }) { return nil }
        if let literal = address(host) { return isPublic(literal) ? url : nil }
        // A single-label name resolves through the local search domains.
        return host.contains(".") ? url : nil
    }

    /// Every address of the URL's host is public (blocking: call off the main thread).
    static func resolvesPublic(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        if let literal = address(host) { return isPublic(literal) }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        var any = false
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let sa = info.pointee.ai_addr else { continue }
            let bytes: [UInt8]
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                bytes = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            case AF_INET6:
                bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
            default: continue
            }
            guard isPublic(bytes) else { return false }
            any = true
        }
        return any
    }

    /// An IP literal's bytes (4 or 16), else nil.
    static func address(_ host: String) -> [UInt8]? {
        let h = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, h, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        if inet_pton(AF_INET6, h, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }

    static func isPublic(_ b: [UInt8]) -> Bool {
        if b.count == 4 {
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _): return false
            case (100, 64...127): return false                 // CGNAT, Tailscale
            case (169, 254), (192, 168): return false
            case (172, 16...31): return false
            case (198, 18...19): return false
            case (192, 0) where b[2] == 0 || b[2] == 2: return false
            case (198, 51) where b[2] == 100, (203, 0) where b[2] == 113: return false
            case (224...255, _): return false                   // multicast, reserved, broadcast
            default: return true
            }
        }
        guard b.count == 16 else { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPublic(Array(b[12...])) }   // ::ffff:a.b.c.d
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) { return isPublic(Array(b[12...])) }  // NAT64
        if b[0..<15].allSatisfy({ $0 == 0 }) { return false }  // :: and ::1
        if b[0..<12].allSatisfy({ $0 == 0 }) { return false }  // IPv4-compatible (deprecated)
        if b[0] & 0xfe == 0xfc { return false }                // ULA fc00::/7
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false } // link-local fe80::/10
        if b[0] == 0xff { return false }                       // multicast
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return false } // documentation
        return true
    }
}
