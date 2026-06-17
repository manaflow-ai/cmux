import Foundation

/// A parsed VNC target: host, port, and optional password.
///
/// Accepts `vnc://[password@]host[:port]`, `host:port`, `host::screen`
/// (RealVNC-style display where `::N` means port `5900 + N` is *not* applied;
/// `::` denotes a raw port), and bare `host`. A display suffix `host:N` where
/// `N < 100` is treated as a screen number (port `5900 + N`), matching common
/// VNC viewer conventions.
public struct VNCEndpoint: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var password: String?
    /// Account user name, required for Apple Diffie-Hellman auth (macOS Screen
    /// Sharing). Parsed from `vnc://user:password@host`.
    public var username: String?

    public init(host: String, port: UInt16, password: String? = nil, username: String? = nil) {
        self.host = host
        self.port = port
        self.password = password
        self.username = username
    }

    public init?(string raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var password: String?
        var username: String?
        if text.lowercased().hasPrefix("vnc://") {
            text = String(text.dropFirst("vnc://".count))
        }
        // Strip a trailing path/query, if any.
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        // Optional userinfo: `password@host`, `:password@host`, or
        // `user:password@host` (the last form carries the account name needed
        // for Apple DH auth).
        if let at = text.lastIndex(of: "@") {
            let userinfo = String(text[..<at])
            text = String(text[text.index(after: at)...])
            if let colon = userinfo.firstIndex(of: ":") {
                let user = String(userinfo[..<colon])
                let pass = String(userinfo[userinfo.index(after: colon)...])
                username = user.isEmpty ? nil : user
                password = pass.isEmpty ? nil : pass
            } else {
                password = userinfo.isEmpty ? nil : userinfo
            }
        }
        guard !text.isEmpty else { return nil }

        // IPv6 literal in brackets: [::1]:5900 (checked first so its inner "::"
        // is not mistaken for the raw-port separator below).
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            var port: UInt16 = 5900
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let parsed = UInt16(rest.dropFirst()) {
                port = parsed
            }
            self.init(host: host, port: port, password: password, username: username)
            return
        }

        // Raw port separator "host::5905" beats the display-number heuristic.
        if let rawPortRange = text.range(of: "::") {
            let host = String(text[..<rawPortRange.lowerBound])
            let portText = String(text[rawPortRange.upperBound...])
            guard !host.isEmpty, let port = UInt16(portText) else { return nil }
            self.init(host: host, port: port, password: password, username: username)
            return
        }

        if let colon = text.lastIndex(of: ":") {
            let host = String(text[..<colon])
            let suffix = String(text[text.index(after: colon)...])
            guard !host.isEmpty, let value = Int(suffix), value >= 0 else { return nil }
            // Small numbers are VNC display numbers (5900 + N); larger are ports.
            let port = value < 100 ? UInt16(5900 + value) : UInt16(clamping: value)
            self.init(host: host, port: port, password: password, username: username)
            return
        }

        self.init(host: text, port: 5900, password: password, username: username)
    }

    /// A user-facing label like `host:5901`.
    public var displayLabel: String { "\(host):\(port)" }
}
