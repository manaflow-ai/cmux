import Darwin
import Foundation

/// What the host fetches for a markdown file's remote images (coordinator decision for S6: the
/// host fetches them, `markdown.remoteImages`, default on, so the page CSP stays strict; the
/// fetch replaces `img-src https:`). A document chose the URL, so: https only, no URL
/// credentials, no `localhost` or `.local` names, every address public (``IPAddress/isPublic``),
/// at most ``maximumRedirects`` redirects each checked the same way, image types only, at most
/// ``maximumBytes``.
nonisolated enum RemoteImagePolicy {
    static let maximumBytes = 10 * 1024 * 1024
    static let maximumRedirects = 3
    static let timeout: Duration = .seconds(15)

    static let imageTypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/svg+xml", "image/bmp",
        "image/x-icon", "image/vnd.microsoft.icon", "image/apng",
    ]

    /// The URL itself may be fetched (its resolved addresses are checked separately).
    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = host(of: url), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        if let literal = IPAddress(literal: host) { return literal.isPublic }
        return true
    }

    /// The host without IPv6 brackets, lowercased.
    static func host(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }

    /// The normalized image type of a `Content-Type` value, nil for anything that is not an image.
    static func imageType(_ value: String?) -> String? {
        guard let base = value?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
              imageTypes.contains(base) else { return nil }
        return base
    }

    /// The GET the host sends to `address` for `url`: no cookies, credentials or auth headers.
    static func request(for url: URL, address: IPAddress) -> RemoteImageRequest {
        let host = Self.host(of: url) ?? ""
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true) { target += "?" + query }
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        return RemoteImageRequest(address: address, host: host, port: url.port ?? 443, target: target, headers: [
            "Host": hostHeader, "Accept": "image/*", "Accept-Encoding": "identity", "Connection": "close", "User-Agent": "cmux",
        ])
    }

    /// The URL as one path component: base64url without padding.
    static func encode(_ url: URL) -> String {
        Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ component: String) -> URL? {
        var text = component.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), let string = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: string)
    }
}

/// An IPv4 or IPv6 address as bytes, classified by range.
nonisolated enum IPAddress: Hashable, Sendable {
    case v4([UInt8])
    case v6([UInt8])

    /// A dotted IPv4 or an IPv6 literal (no brackets, no zone); nil for a name.
    init?(literal: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            self = .v4(withUnsafeBytes(of: &v4) { Array($0) })
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            self = .v6(withUnsafeBytes(of: &v6) { Array($0) })
            return
        }
        return nil
    }

    /// Not loopback, private (RFC 1918, CGNAT, IPv6 ULA fc00::/7), link-local (169.254.0.0/16,
    /// fe80::/10), unspecified, multicast, broadcast or reserved; an IPv4-mapped, IPv4-compatible or
    /// NAT64 IPv6 address is classified by the IPv4 address it carries.
    var isPublic: Bool {
        switch self {
        case .v4(let b):
            guard b.count == 4 else { return false }
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168), (100, 64...127), (172, 16...31), (198, 18...19): return false
            case (192, 0) where b[2] == 0 || b[2] == 2: return false
            case (224...255, _): return false
            default: return true
            }
        case .v6(let b):
            guard b.count == 16 else { return false }
            let prefix12 = Array(b.prefix(12))
            if prefix12 == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] || prefix12 == Array(repeating: 0, count: 12)
                || Array(b.prefix(12)) == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {
                // ::ffff:a.b.c.d, ::a.b.c.d (also :: and ::1), 64:ff9b::a.b.c.d.
                return IPAddress.v4(Array(b.suffix(4))).isPublic
            }
            if b[0] & 0xfe == 0xfc { return false }          // fc00::/7
            if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return false } // fe80::/10
            if b[0] == 0xff { return false }                 // multicast
            if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return false } // documentation
            return true
        }
    }
}
