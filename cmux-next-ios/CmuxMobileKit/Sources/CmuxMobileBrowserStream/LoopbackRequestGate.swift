import Foundation

/// Checks every HTTP request a native tab sends to a forwarded `localhost:<port>`
/// before its bytes go to the Mac's loopback. iOS WebKit has no Private Network
/// Access checks (Chromium's, which the Mac's own browser applies), so this stands
/// in for them:
///
/// - **Host.** The request must name `localhost`, `127.0.0.1` or `[::1]` with this
///   port: a page on another host that DNS-rebinds to `127.0.0.1` is refused.
/// - **Another site.** A request from another site (`Sec-Fetch-Site: cross-site`,
///   or an `Origin` that is not a loopback origin) is refused, except a top-level
///   page load (`Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document`, `GET`), as
///   desktop browsers and SameSite=Lax cookies allow: a sign-in callback works, an
///   internet page's script can't send requests into the Mac's dev server.
/// - **HTTP only.** Anything else (TLS included: the Mac's certificate isn't trusted
///   on this iPhone anyway) is refused. A chunked request body is refused (WebKit
///   sends none). A WebSocket passes unchecked only once the Mac answered `101`.
///
/// Bytes are released only once their request head passed: a head that is still
/// arriving is held back. One gate per connection; the two directions share it.
final class LoopbackRequestGate: @unchecked Sendable {
    enum Verdict: Equatable {
        /// These bytes may go to the Mac (maybe none yet: a head still arriving).
        case forward(Data)
        case refuse(String)
    }

    private enum State {
        /// Reading request heads (and skipping bodies by `Content-Length`).
        case requests
        /// An upgrade request went to the Mac: nothing more until its reply.
        case awaitingUpgrade
        /// The Mac switched protocols (a WebSocket): bytes pass as they are.
        case upgraded
    }

    let port: UInt16
    private let lock = NSLock()
    private var head = Data()
    private var bodyLeft = 0
    private var state = State.requests
    /// The start of the Mac's reply to an upgrade request, until its status is known.
    private var reply = Data()

    /// The longest request head held before a request is refused.
    static let maximumHead = 64 * 1024

    init(port: UInt16) {
        self.port = port
    }

    /// The next bytes from the page: what may go to the Mac now, or why the connection ends.
    func check(_ data: Data) -> Verdict {
        lock.withLock { checkLocked(data) }
    }

    /// The Mac's first reply bytes after an upgrade request: `101` opens the connection.
    func replied(_ data: Data) {
        lock.withLock {
            guard case .awaitingUpgrade = state else { return }
            // The status may arrive split across reads: decide once it is whole.
            reply.append(data.prefix(16 - reply.count))
            let status = Data("HTTP/1.1 101".utf8)
            if reply.count < status.count, status.starts(with: reply) { return }
            state = reply.starts(with: status) ? .upgraded : .requests
            reply = Data()
        }
    }

    private func checkLocked(_ data: Data) -> Verdict {
        switch state {
        case .upgraded:
            return .forward(data)
        case .awaitingUpgrade:
            return .refuse("bytes before the upgrade reply")
        case .requests:
            break
        }
        var out = Data()
        var rest = data[...]
        while !rest.isEmpty {
            if bodyLeft > 0 {
                let take = min(bodyLeft, rest.count)
                out.append(contentsOf: rest.prefix(take))
                bodyLeft -= take
                rest = rest.dropFirst(take)
                continue
            }
            if case .awaitingUpgrade = state { return .refuse("bytes after an upgrade request") }
            head.append(contentsOf: rest)
            rest = Data()[...]
            guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
                if head.count > Self.maximumHead { return .refuse("request head too long") }
                // Not an HTTP request from its first bytes on (TLS, another protocol).
                if !head.isEmpty, !Self.looksLikeRequestStart(head) { return .refuse("not an HTTP request") }
                return .forward(out)
            }
            let request = head[head.startIndex..<end.lowerBound]
            let after = Data(head[end.upperBound...])
            if let refusal = inspect(request) { return .refuse(refusal) }
            out.append(head[head.startIndex..<end.upperBound])
            head = Data()
            rest = after[...]
        }
        return .forward(out)
    }

    /// `GET /`, `POST /a`...: an HTTP method, then a space.
    private static func looksLikeRequestStart(_ head: Data) -> Bool {
        let prefix = head.prefix(8)
        guard let text = String(data: prefix, encoding: .ascii) else { return false }
        let method = text.prefix { $0 != " " }
        guard !method.isEmpty, method.count < text.count || text.count < 8 else { return false }
        return method.allSatisfy { $0.isUppercase && $0.isLetter }
    }

    /// Nil when the request may go to the Mac; else why not.
    private func inspect(_ request: Data) -> String? {
        guard let text = String(data: request, encoding: .utf8) ?? String(data: request, encoding: .isoLatin1) else {
            return "not an HTTP request"
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return "not an HTTP request" }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        guard let host = headers["host"], isLoopback(authority: host) else { return "the request names another host" }
        let site = headers["sec-fetch-site"]?.lowercased()
        let origin = headers["origin"]
        let crossSite = site == "cross-site"
            || (origin.map { !Self.isLoopbackOrigin($0) } ?? false && site != "same-origin" && site != "same-site")
        if crossSite {
            // A page load the person sees (a link or a sign-in callback from another site).
            let topLevel = parts[0] == "GET" && headers["sec-fetch-mode"]?.lowercased() == "navigate"
                && headers["sec-fetch-dest"]?.lowercased() == "document"
            if !topLevel { return "a request from another site" }
        }
        if headers["transfer-encoding"] != nil { return "a chunked request body" }
        if headers["upgrade"] != nil {
            state = .awaitingUpgrade
        } else if let length = headers["content-length"] {
            guard let count = Int(length), count >= 0 else { return "a bad Content-Length" }
            bodyLeft = count
        }
        return nil
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]"]

    /// `http://localhost:5173`: a loopback origin, any port (another dev server on this Mac is the same site).
    /// `null` (a sandboxed frame, a file) is not.
    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return loopbackHosts.contains(host) || host == "::1"
    }

    /// `localhost:3000`, `127.0.0.1:3000`, `[::1]:3000` for this port.
    private func isLoopback(authority: String) -> Bool {
        let value = authority.lowercased()
        let host: String
        let portText: String?
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return false }
            host = String(value[...close])
            let tail = value[value.index(after: close)...]
            if tail.isEmpty {
                portText = nil
            } else if tail.hasPrefix(":") {
                portText = String(tail.dropFirst())
            } else {
                return false
            }
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
