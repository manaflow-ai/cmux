import Foundation

/// Checks every HTTP request a native tab sends to a forwarded `localhost:<port>`
/// before its bytes go to the Mac's loopback. iOS WebKit has no Private Network
/// Access checks (Chromium's, which the Mac's own browser applies), so this stands
/// in for them:
///
/// - **Host.** The request must name `localhost`, `127.0.0.1` or `[::1]` with this
///   port: a page on another host that DNS-rebinds to `127.0.0.1` is refused.
/// - **Another site.** A request the browser marks `Sec-Fetch-Site: cross-site`,
///   or whose `Origin` is not a loopback origin, is refused: an internet page in
///   another native tab can't send requests into the Mac's dev server.
///
/// It reads each request's head, skips its body by `Content-Length`, and stops
/// checking after a WebSocket upgrade or a chunked body (the rest of that
/// connection passes as is). A TLS connection (`https://localhost`) passes: the
/// certificate binds its host, and its bytes can't be read here.
struct LoopbackRequestGate {
    enum Verdict: Equatable {
        case pass
        case refuse(String)
    }

    let port: UInt16
    private var head = Data()
    private var bodyLeft = 0
    private var passthrough = false
    private var started = false

    /// The longest request head read before a request is refused.
    static let maximumHead = 64 * 1024

    init(port: UInt16) {
        self.port = port
    }

    /// Feeds the next bytes from the page; refuses the connection at the first bad request.
    mutating func check(_ data: Data) -> Verdict {
        if passthrough { return .pass }
        if !started, let first = data.first {
            started = true
            // A TLS ClientHello (https://localhost:<port>).
            if first == 0x16 {
                passthrough = true
                return .pass
            }
        }
        var rest = data[...]
        while !rest.isEmpty {
            if bodyLeft > 0 {
                let skip = min(bodyLeft, rest.count)
                bodyLeft -= skip
                rest = rest.dropFirst(skip)
                continue
            }
            head.append(contentsOf: rest)
            rest = Data()[...]
            guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
                return head.count > Self.maximumHead ? .refuse("request head too long") : .pass
            }
            let request = head[head.startIndex..<end.lowerBound]
            let after = head[end.upperBound...]
            head = Data()
            switch inspect(request) {
            case .refuse(let reason):
                return .refuse(reason)
            case .pass:
                break
            }
            if passthrough { return .pass }
            rest = Data(after)[...]
        }
        return .pass
    }

    private mutating func inspect(_ request: Data) -> Verdict {
        guard let text = String(data: request, encoding: .utf8) ?? String(data: request, encoding: .isoLatin1) else {
            return .refuse("not an HTTP request")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        guard requestLine.split(separator: " ").count == 3, requestLine.hasSuffix("HTTP/1.1") || requestLine.hasSuffix("HTTP/1.0") else {
            return .refuse("not an HTTP request")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        guard let host = headers["host"], isLoopback(authority: host) else {
            return .refuse("the request names another host")
        }
        if headers["sec-fetch-site"]?.lowercased() == "cross-site" {
            return .refuse("a request from another site")
        }
        if let origin = headers["origin"], origin != "null",
           !(URL(string: origin).flatMap { $0.host(percentEncoded: false) }.map { Self.loopbackHosts.contains($0.lowercased()) } ?? false) {
            return .refuse("a request from another site")
        }
        if headers["upgrade"] != nil || headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            passthrough = true
        } else if let length = headers["content-length"].flatMap({ Int($0) }), length > 0 {
            bodyLeft = length
        }
        return .pass
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// `localhost:3000`, `127.0.0.1:3000`, `[::1]:3000` for this port.
    private func isLoopback(authority: String) -> Bool {
        let value = authority.lowercased()
        let host: String
        let portText: String?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return false }
            host = String(value[...close])
            let tail = value[value.index(after: close)...]
            portText = tail.hasPrefix(":") ? String(tail.dropFirst()) : nil
        } else if let colon = value.lastIndex(of: ":") {
            host = String(value[..<colon])
            portText = String(value[value.index(after: colon)...])
        } else {
            host = value
            portText = nil
        }
        guard Self.loopbackHosts.contains(host) else { return false }
        if let portText { return UInt16(portText) == port }
        // No port: the default one (`localhost` alone is port 80).
        return port == 80
    }
}
