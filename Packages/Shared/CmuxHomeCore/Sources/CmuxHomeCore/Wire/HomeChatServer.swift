public import Foundation

/// Which `cmux.wire/1` server carries DMs and group chats
/// (plans/cmux-next/dm-group-chat-DESIGN.md section 4.5).
public enum HomeChatServer: Hashable, Sendable, Codable {
    /// The cmux cloud for this build, with Stack sign-in.
    case hosted
    /// A self-hosted `cmux-chat-server` on the user's tailnet (no bearer;
    /// the server identifies the caller by Tailscale). Always a URL that
    /// ``selfHostedURL(_:)`` accepted.
    case selfHosted(URL)

    /// Why ``selfHostedURL(_:)`` refused an address.
    public enum AddressProblem: Error, Hashable, Sendable {
        /// Not an `http` or `https` URL with a host.
        case notAURL
        /// The host is neither a MagicDNS `*.ts.net` name nor a tailnet
        /// address (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`).
        case notTailnet
    }

    /// The server's base URL for a typed address, or why it is refused. A
    /// bare host gets `http://` and port 7320 (the server's default).
    /// Accepted hosts: `*.ts.net`, `100.64.0.0/10` and `fd7a:115c:a1e0::/48`,
    /// so a self-hosted choice can never send chats to a public address.
    ///
    /// ```swift
    /// try HomeChatServer.selfHostedURL("mini.tail1234.ts.net")
    /// // http://mini.tail1234.ts.net:7320
    /// ```
    public static func selfHostedURL(_ typed: String) throws(AddressProblem) -> URL {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .notAURL }
        if !text.contains("://") {
            let bracketed = text.hasPrefix("[")
            let hasPort = bracketed ? text.contains("]:") : (text.split(separator: ":").count == 2)
            let isBareIPv6 = !bracketed && text.split(separator: ":").count > 2
            let host = isBareIPv6 ? "[\(text)]" : text
            text = "http://" + host + (hasPort ? "" : ":7320")
        }
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty else { throw .notAURL }
        guard Self.isTailnetHost(host) else { throw .notTailnet }
        components.scheme = scheme
        // Host names compare without case; an IPv6 literal stays as typed.
        if !host.contains(":") { components.host = host.lowercased() }
        components.path = components.path == "/" ? "" : components.path
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let url = components.url else { throw .notAURL }
        return url
    }

    /// Whether `host` (a name, an IPv4 or an IPv6 address, brackets
    /// optional) is on a tailnet by its name or address alone.
    public static func isTailnetHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name.hasSuffix(".ts.net"), name.count > ".ts.net".count { return true }
        if let v4 = ipv4(name) { return v4.0 == 100 && (64...127).contains(v4.1) }
        if let v6 = ipv6Prefix(name) { return v6 == [0xfd7a, 0x115c, 0xa1e0] }
        return false
    }

    private static func ipv4(_ text: String) -> (UInt8, UInt8)? {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return nil }
        let bytes = pieces.compactMap { piece -> UInt8? in
            guard !piece.isEmpty, piece.count <= 3, piece.allSatisfy(\.isNumber) else { return nil }
            return UInt8(piece)
        }
        guard bytes.count == 4 else { return nil }
        return (bytes[0], bytes[1])
    }

    /// The first three 16-bit groups of an IPv6 address, or nil.
    private static func ipv6Prefix(_ text: String) -> [UInt16]? {
        guard text.contains(":") else { return nil }
        let address = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        let halves = address.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        let head = halves[0].isEmpty ? [] : halves[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let groups = head.compactMap { UInt16($0, radix: 16) }
        guard groups.count == head.count, head.allSatisfy({ (1...4).contains($0.count) }) else { return nil }
        // "fd7a:115c:a1e0::1" has the three groups before "::"; fewer means zeros follow.
        var prefix = groups
        if halves.count == 2 { while prefix.count < 3 { prefix.append(0) } }
        guard prefix.count >= 3 else { return nil }
        return Array(prefix.prefix(3))
    }
}
