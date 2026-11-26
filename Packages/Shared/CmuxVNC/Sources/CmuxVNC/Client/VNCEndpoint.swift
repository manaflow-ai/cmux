import Foundation

/// Credentials for one server. Apple DH (macOS Screen Sharing) needs both;
/// classic VNC authentication needs only the password.
public struct VNCCredentials: Sendable, Equatable {
    public var username: String?
    public var password: String?

    public init(username: String? = nil, password: String? = nil) {
        self.username = username.flatMap { $0.isEmpty ? nil : $0 }
        self.password = password.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A VNC server address: `host`, `host:port`, `host:N` (display N, port
/// 5900 + N when N < 100), `[v6]:port`, or `vnc://[user[:password]@]host[:port]`.
public struct VNCEndpoint: Sendable, Equatable, Hashable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16 = 5900) {
        self.host = host
        self.port = port
    }

    /// The address plus any credentials embedded in a `vnc://` URL.
    public struct Parsed: Sendable, Equatable {
        public var endpoint: VNCEndpoint
        public var credentials: VNCCredentials
    }

    public static func parse(_ raw: String) -> Parsed? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("vnc://") { text = String(text.dropFirst(6)) }
        if let slash = text.firstIndex(where: { $0 == "/" || $0 == "?" }) { text = String(text[..<slash]) }
        var credentials = VNCCredentials()
        if let at = text.lastIndex(of: "@") {
            let info = text[..<at]
            text = String(text[text.index(after: at)...])
            if let colon = info.firstIndex(of: ":") {
                credentials = VNCCredentials(username: String(info[..<colon]).removingPercentEncoding,
                                             password: String(info[info.index(after: colon)...]).removingPercentEncoding)
            } else {
                credentials = VNCCredentials(username: String(info).removingPercentEncoding)
            }
        }
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex) ..< close])
            let rest = text[text.index(after: close)...]
            var port: UInt16 = 5900
            if rest.hasPrefix(":") {
                guard let value = UInt16(rest.dropFirst()) else { return nil }
                port = value
            }
            guard !host.isEmpty else { return nil }
            return Parsed(endpoint: VNCEndpoint(host: host, port: port), credentials: credentials)
        }
        if let range = text.range(of: "::") {
            guard let port = UInt16(text[range.upperBound...]), range.lowerBound > text.startIndex else { return nil }
            return Parsed(endpoint: VNCEndpoint(host: String(text[..<range.lowerBound]), port: port), credentials: credentials)
        }
        if let colon = text.lastIndex(of: ":") {
            let host = String(text[..<colon])
            guard !host.isEmpty, let value = Int(text[text.index(after: colon)...]), value >= 0, value <= 65535 else { return nil }
            let port = value < 100 ? UInt16(5900 + value) : UInt16(value)
            return Parsed(endpoint: VNCEndpoint(host: host, port: port), credentials: credentials)
        }
        return Parsed(endpoint: VNCEndpoint(host: text), credentials: credentials)
    }

    /// `host:port` (IPv6 hosts in brackets).
    public var label: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}
