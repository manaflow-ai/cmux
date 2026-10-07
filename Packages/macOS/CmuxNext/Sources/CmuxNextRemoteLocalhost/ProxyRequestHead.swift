public import Foundation

/// The request head Chromium sends to an HTTP proxy: `CONNECT host:port`
/// (HTTPS, WebSocket, HTTP/2 over TLS) or an absolute-form request
/// (`GET http://localhost:3000/path HTTP/1.1`) for plain HTTP.
public struct ProxyRequestHead: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Byte tunnel after `200 Connection Established`.
        case connect
        /// Forwarded as origin form with `Connection: close`, then a tunnel.
        case forward
    }

    public var kind: Kind
    public var method: String
    public var host: String
    public var port: UInt16
    /// Origin-form path with query (forward only).
    public var path: String
    public var version: String
    /// Header fields in order, names as sent.
    public var headers: [(name: String, value: String)]

    /// Longest head the proxy reads before refusing (Chromium sends far less).
    public static let maxBytes = 16 * 1024

    public enum ParseError: Error, Sendable, Equatable {
        /// No blank line yet: read more.
        case incomplete
        case tooLarge
        case malformed(String)
        /// A scheme the proxy does not forward (only http absolute form).
        case unsupportedScheme(String)
    }

    /// Parses a head from the start of `buffer`. Returns the head and the
    /// number of bytes it used; the rest is body or tunnel payload.
    public static func parse(_ buffer: Data) throws(ParseError) -> (ProxyRequestHead, Int) {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            throw buffer.count > maxBytes ? .tooLarge : .incomplete
        }
        let consumed = end.upperBound - buffer.startIndex
        guard consumed <= maxBytes else { throw .tooLarge }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            throw .malformed("head is not UTF-8")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { throw .malformed("request line") }
        let method = String(requestLine[0]), target = String(requestLine[1]), version = String(requestLine[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { throw .malformed("version \(version)") }
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw .malformed("header") }
            let name = String(line[..<colon])
            guard !name.contains(" "), !name.contains("\t") else { throw .malformed("header name") }
            headers.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        if method == "CONNECT" {
            let (host, port) = try authority(target, defaultPort: nil)
            return (ProxyRequestHead(kind: .connect, method: method, host: host, port: port, path: "",
                                     version: version, headers: headers), consumed)
        }
        guard let components = URLComponents(string: target), let scheme = components.scheme?.lowercased() else {
            throw .malformed("absolute-form target")
        }
        guard scheme == "http" else { throw .unsupportedScheme(scheme) }
        guard let rawHost = components.percentEncodedHost, !rawHost.isEmpty else { throw .malformed("host") }
        let port = components.port ?? 80
        guard (1...65535).contains(port) else { throw .malformed("port") }
        var path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        let host = rawHost.hasPrefix("[") ? String(rawHost.dropFirst().dropLast()) : rawHost
        return (ProxyRequestHead(kind: .forward, method: method, host: host, port: UInt16(port), path: path,
                                 version: version, headers: headers), consumed)
    }

    /// The `Proxy-Authorization` value, if any.
    public var proxyAuthorization: String? {
        headers.first { $0.name.caseInsensitiveCompare("Proxy-Authorization") == .orderedSame }?.value
    }

    /// The head to send to the origin: origin form, no proxy or hop-by-hop
    /// fields, `Connection: close` so the proxy connection carries exactly
    /// one request.
    public func originHead() -> Data {
        let dropped: Set<String> = ["proxy-authorization", "proxy-connection", "connection", "keep-alive"]
        var text = "\(method) \(path) \(version)\r\n"
        for (name, value) in headers where !dropped.contains(name.lowercased()) {
            text += "\(name): \(value)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }

    public static func == (lhs: ProxyRequestHead, rhs: ProxyRequestHead) -> Bool {
        lhs.kind == rhs.kind && lhs.method == rhs.method && lhs.host == rhs.host && lhs.port == rhs.port
            && lhs.path == rhs.path && lhs.version == rhs.version
            && lhs.headers.map(\.name) == rhs.headers.map(\.name) && lhs.headers.map(\.value) == rhs.headers.map(\.value)
    }

    /// `host:port` or `[v6]:port`.
    private static func authority(_ text: String, defaultPort: UInt16?) throws(ParseError) -> (String, UInt16) {
        let host: Substring, portText: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { throw .malformed("authority") }
            host = text[text.index(after: text.startIndex)..<close]
            let rest = text[text.index(after: close)...]
            portText = rest.hasPrefix(":") ? rest.dropFirst() : (rest.isEmpty ? nil : rest)
        } else {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw .malformed("authority") }
            host = parts[0]
            portText = parts.count == 2 ? parts[1] : nil
        }
        guard !host.isEmpty else { throw .malformed("authority host") }
        guard let port = portText.flatMap({ UInt16($0) }) ?? defaultPort, port != 0 else { throw .malformed("authority port") }
        return (String(host), port)
    }
}
