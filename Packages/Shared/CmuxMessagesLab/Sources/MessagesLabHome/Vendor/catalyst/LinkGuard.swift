import Foundation
import Darwin
import os // cmux: OSAllocatedUnfairLock

/// What a link preview may fetch. Previews start from URLs in INCOMING messages
/// (agents, other people) and then from the page's og:image URL, so without a
/// guard a message could make the app request http://127.0.0.1:…, a home router,
/// a cloud metadata address or an intranet host and reveal the answer in the card.
///
/// Rules (every request, every redirect, the image too):
/// - http or https only, on the default port only (80 / 443): a preview never
///   needs another port, and other ports are where internal services listen.
/// - No user or password in the URL; names `localhost`, `*.localhost`, `*.local`,
///   `*.internal`, `*.lan`, `*.home.arpa` and single-label names refused.
/// - The host is resolved here (getaddrinfo, off the main thread) and EVERY
///   address must be public: not loopback, private (RFC 1918), CGNAT
///   (100.64.0.0/10, Tailscale), link-local, unique-local, multicast,
///   unspecified, broadcast, benchmark, documentation or reserved, including
///   the IPv4-mapped, IPv4-compatible and NAT64 (64:ff9b::/96) IPv6 forms.
/// - After connecting, the address the request actually went to (URLSession
///   transaction metrics) is checked again and the response is dropped if it is
///   not public (DNS rebinding between our resolution and URLSession's). URLSession
///   cannot be pinned to an address for https (SNI and certificate need the
///   name), so a rebinding race can still send the GET; it cannot return data.
/// - Redirects: at most 5, each target checked by the same rules, https -> http
///   refused.
/// - An ephemeral session: no cookies, cache, credentials or proxies; auth
///   challenges cancelled. HTML is read up to 512 KB and stops at </head>;
///   an image up to 5 MB.
enum LinkGuard {
    enum Refusal: Error, Equatable, CustomStringConvertible {
        case scheme, port, credentials, name(String), resolve(String), address(String)
        case redirectLimit, downgrade, tooLarge, connectedTo(String), network(String)
        var description: String {
            switch self {
            case .scheme: return "scheme"
            case .port: return "port"
            case .credentials: return "credentials in the URL"
            case let .name(n): return "name \(n)"
            case let .resolve(n): return "\(n) does not resolve"
            case let .address(a): return "address \(a)"
            case .redirectLimit: return "more than 5 redirects"
            case .downgrade: return "https -> http redirect"
            case .tooLarge: return "too large"
            case let .connectedTo(a): return "connected to \(a)"
            case let .network(e): return "network: \(e)"
            }
        }
    }
    static let maxRedirects = 5
    static let htmlLimit = 512 * 1024
    static let imageLimit = 5 * 1024 * 1024

    // MARK: URL and name

    #if MESSAGESLAB_SELFTEST
    /// Self-test builds only (`SELFTEST=1 ./build.sh`): the one loopback origin of the
    /// self-test's local page ("127.0.0.1:port"). Release builds have no exception.
    static var testOrigin: String?
    #endif
    static func isTestOrigin(_ u: URL) -> Bool {
        #if MESSAGESLAB_SELFTEST
        if let o = testOrigin, u.scheme == "http", let h = u.host, let p = u.port, "\(h):\(p)" == o { return true }
        #endif
        return false
    }
    static func isTestAddress(_ a: String) -> Bool {
        #if MESSAGESLAB_SELFTEST
        if testOrigin != nil, a == "127.0.0.1" { return true }
        #endif
        return false
    }

    static func checkURL(_ u: URL) -> Refusal? {
        if isTestOrigin(u) { return nil }
        // http or https only, and only a URL the markdown link policy accepts (no control
        // characters, no obfuscated scheme; MarkdownParser.swift). Extra host schemes never fetch.
        guard let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              MarkdownLinkPolicy.allows(u) else { return .scheme }
        if let p = u.port, p != (scheme == "https" ? 443 : 80) { return .port }
        if u.user != nil || u.password != nil { return .credentials }
        guard var host = u.host?.lowercased(), !host.isEmpty else { return .name("(none)") }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        if isIPLiteral(host) { return isPublicAddress(host) ? nil : .address(host) }
        if host == "localhost" || !host.contains(".") { return .name(host) }
        for s in [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".intranet", ".corp"] where host.hasSuffix(s) { return .name(host) }
        return nil
    }

    /// The URL's checks, then its host's addresses (blocking: call off main).
    static func check(_ u: URL) -> Refusal? {
        if isTestOrigin(u) { return nil }
        if let r = checkURL(u) { return r }
        var host = u.host ?? ""
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        if isIPLiteral(host) { return nil }
        let addrs = resolve(host)
        if addrs.isEmpty { return .resolve(host) }
        if let bad = addrs.first(where: { !isPublicAddress($0) }) { return .address(bad) }
        return nil
    }

    // MARK: Addresses

    static func isIPLiteral(_ s: String) -> Bool {
        var a4 = in_addr(), a6 = in6_addr()
        // SAFETY: inet_pton reads the NUL-terminated copy of `s` Swift passes for the call and writes one address of
        // its family's size into the local a4 (4 bytes) or a6 (16 bytes), during the call only.
        return unsafe inet_pton(AF_INET, s, &a4) == 1 || inet_pton(AF_INET6, s, &a6) == 1
    }

    /// Every address of a name, numeric (getaddrinfo; IPv4 forms like 2130706433 or 0x7f.1 resolve too).
    static func resolve(_ host: String) -> [String] {
        // SAFETY: the hints' pointers are null (no name, address or next hint).
        var hints = unsafe addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                    ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        // SAFETY: getaddrinfo reads the host's C string copy and the local hints during the call and stores in `res`
        // a list it allocated; `numeric` copies the addresses out, then the list is freed exactly once (the defer).
        guard unsafe getaddrinfo(host, nil, &hints, &res) == 0, let first = unsafe res else {
            // AI_ADDRCONFIG drops families without a route; ask again without it.
            hints.ai_flags = 0
            guard unsafe getaddrinfo(host, nil, &hints, &res) == 0, let again = unsafe res else { return [] }
            defer { unsafe freeaddrinfo(again) }
            return unsafe numeric(again)
        }
        defer { unsafe freeaddrinfo(first) }
        return unsafe numeric(first)
    }
    private static func numeric(_ list: UnsafeMutablePointer<addrinfo>?) -> [String] {
        var out: [String] = []
        // SAFETY: `list` is a getaddrinfo list its caller frees only after this returns: every node is live, its
        // ai_addr points to ai_addrlen bytes of address and a null ai_next ends the list. getnameinfo writes at most
        // buf.count bytes, NUL-terminated, into the local buffer, during the call only.
        var p = unsafe list
        while let ai = unsafe p {
            var buf = [CChar](repeating: 0, count: Int(truncatingIfNeeded: NI_MAXHOST)) /* a constant that widens exactly */
            if unsafe getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf)
                out.append(s.split(separator: "%").first.map(String.init) ?? s)   // drop a scope id
            }
            p = unsafe ai.pointee.ai_next
        }
        return out
    }

    static func isPublicAddress(_ s: String) -> Bool {
        var a4 = in_addr(), a6 = in6_addr()
        // SAFETY: as isIPLiteral: inet_pton writes one address of its family's size into the local a4 or a6.
        if unsafe inet_pton(AF_INET, s, &a4) == 1 {
            // cmux: the address's bytes in network order, read from the value instead of through a raw pointer.
            let v = UInt32(bigEndian: a4.s_addr)
            return isPublicV4([UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
                               UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
        }
        // SAFETY: as above.
        if unsafe inet_pton(AF_INET6, s, &a6) == 1 {
            let b = a6.__u6_addr.__u6_addr8 // cmux: the 16 bytes as a tuple value, no raw pointer
            return isPublicV6([b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15])
        }
        return false
    }

    /// Four bytes, network order.
    static func isPublicV4(_ b: [UInt8]) -> Bool {
        let (a, c, d) = (b[0], b[1], b[2])
        switch a {
        case 0, 10, 127: return false                                  // this network, private, loopback
        case 100 where c >= 64 && c <= 127: return false               // CGNAT 100.64.0.0/10 (Tailscale)
        case 169 where c == 254: return false                          // link-local, cloud metadata
        case 172 where c >= 16 && c <= 31: return false                // private
        case 192 where c == 168: return false                          // private
        case 192 where c == 0 && d == 0: return false                  // IETF protocol assignments
        case 192 where c == 0 && d == 2: return false                  // TEST-NET-1
        case 198 where c == 18 || c == 19: return false                // benchmarking
        case 198 where c == 51 && d == 100: return false               // TEST-NET-2
        case 203 where c == 0 && d == 113: return false                // TEST-NET-3
        case 224...255: return false                                   // multicast, reserved, broadcast
        default: return true
        }
    }

    /// Sixteen bytes.
    static func isPublicV6(_ b: [UInt8]) -> Bool {
        // checked reads and clamped slices ; not sixteen bytes is not public.
        guard b.count == 16 else { return false }
        func at(_ i: Int) -> UInt8? { b[checked: i] }
        func v4(_ lo: Int) -> Bool { isPublicV4(Array(b.slice(lo, lo + 4))) }
        let zero10 = b.slice(0, 10).allSatisfy { $0 == 0 }
        if b.allSatisfy({ $0 == 0 }) { return false }                                    // ::
        if b.slice(0, 15).allSatisfy({ $0 == 0 }) && at(15) == 1 { return false }               // ::1
        if zero10 && at(10) == 0xff && at(11) == 0xff { return v4(12) }                       // ::ffff:a.b.c.d
        if b.slice(0, 12).allSatisfy({ $0 == 0 }) { return v4(12) }                           // ::a.b.c.d (compatible)
        if at(0) == 0x00 && at(1) == 0x64 && at(2) == 0xff && at(3) == 0x9b && b.slice(4, 12).allSatisfy({ $0 == 0 }) {
            return v4(12)                                                                     // NAT64 64:ff9b::/96
        }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return false }                         // fe80::/10 link-local
        if b[0] == 0xfe && (b[1] & 0xc0) == 0xc0 { return false }                         // fec0::/10 site-local
        if (b[0] & 0xfe) == 0xfc { return false }                                         // fc00::/7 unique-local
        if b[0] == 0xff { return false }                                                  // multicast
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false }  // 2001:db8::/32 documentation
        if at(0) == 0x01 && b.slice(1, 8).allSatisfy({ $0 == 0 }) { return false }              // 100::/64 discard
        if at(0) == 0x20 && at(1) == 0x02 { return v4(2) }                                      // 6to4 2002::/16 embeds v4
        return true
    }
}

/// GETs through LinkGuard: an ephemeral session, redirects re-checked, the
/// connected address re-checked, a size cap. One instance, a background queue.
/// cmux: Sendable (URLSession's delegate protocols are): the jobs, the timeout and the session
/// live behind one checked lock instead of an NSLock and plain vars (p10-stability-040). The
/// delegate methods only adapt URLSession's types to the per-task rules below (`track`, `redirect`,
/// `respond`, `receive`, `connected`, `complete`), which tests drive without the network.
final class GuardedFetcher: NSObject, URLSessionDataDelegate, Sendable {
    static let shared = GuardedFetcher()
    struct Result: Sendable { var data: Data; var url: URL }
    /// Runs on the fetcher's queue, once per `get`.
    typealias Done = @Sendable (Swift.Result<Result, LinkGuard.Refusal>) -> Void
    private struct Job: Sendable {
        var data = Data(); var limit: Int; var stopAtHeadEnd: Bool; var redirects = 0
        var refusal: LinkGuard.Refusal?; var finishedEarly = false
        var done: Done
        var url: URL
        init(limit: Int, stopAtHeadEnd: Bool, url: URL, done: @escaping Done) {
            self.limit = limit; self.stopAtHeadEnd = stopAtHeadEnd; self.url = url; self.done = done
        }
    }
    private struct State: Sendable {
        var jobs: [Int: Job] = [:]
        var timeout: TimeInterval = 8
        var session: URLSession?
    }
    // Lock carve-out: the delegate callbacks (the fetcher's queue) and `get` (any thread) touch it
    // synchronously; nothing slow runs under it (no resolution, no session call).
    private let state = OSAllocatedUnfairLock(initialState: State())
    var timeout: TimeInterval {
        get { state.withLock { $0.timeout } }
        set { state.withLock { $0.timeout = newValue } }
    }
    let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .utility; return q }()
    /// Made on first use (the timeout set before the first fetch configures it), on the fetcher's queue.
    private var session: URLSession {
        let (existing, timeout) = state.withLock { ($0.session, $0.timeout) }
        if let existing { return existing }
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.httpMaximumConnectionsPerHost = 2
        let made = URLSession(configuration: c, delegate: self, delegateQueue: queue)
        let kept = state.withLock { s -> URLSession in
            if let first = s.session { return first }
            s.session = made
            return made
        }
        if kept !== made { made.invalidateAndCancel() }
        return kept
    }

    /// Checks the URL (resolution included), then GETs it. `done` runs on the
    /// fetcher's background queue.
    func get(_ url: URL, limit: Int, html: Bool, done: @escaping Done) {
        queue.addOperation { [self] in
            if let r = LinkGuard.check(url) { done(.failure(r)); return }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            req.httpShouldHandleCookies = false
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            req.setValue(html ? "text/html,application/xhtml+xml" : "image/*", forHTTPHeaderField: "Accept")
            let task = session.dataTask(with: req)
            track(task.taskIdentifier, url: url, limit: limit, html: html, done: done)
            task.resume()
        }
    }

    // MARK: Per-task rules (the delegate methods below call them on the fetcher's queue)

    /// Task `id` fetches `url`: at most `limit` bytes; `html`: stop at `</head>` (a longer page is cut, not refused).
    func track(_ id: Int, url: URL, limit: Int, html: Bool, done: @escaping Done) {
        let job = Job(limit: limit, stopAtHeadEnd: html, url: url, done: done)
        state.withLock { $0.jobs[id] = job }
    }

    /// Whether task `id` follows a redirect to `next`; false refuses it (the job keeps the refusal
    /// and the caller cancels the task). nil: no such task.
    func redirect(_ id: Int, to next: URL) -> Bool? {
        guard let j = state.withLock({ $0.jobs[id] }) else { return nil }
        // cmux: decided outside the lock (LinkGuard.check resolves the name); the delegate queue is serial.
        let refusal: LinkGuard.Refusal?
        if j.redirects + 1 > LinkGuard.maxRedirects { refusal = .redirectLimit }
        else if j.url.scheme?.lowercased() == "https" && next.scheme?.lowercased() == "http" { refusal = .downgrade }
        else { refusal = LinkGuard.check(next) }
        update(id) { job in
            job.redirects += 1
            if let refusal { job.refusal = refusal } else { job.url = next }
        }
        return refusal == nil
    }

    /// Whether task `id` reads a response of `expectedLength` bytes (-1: unknown); false refuses it
    /// as too large. An HTML page is never refused for its length (it stops at `</head>`).
    func respond(_ id: Int, expectedLength: Int64) -> Bool {
        let tooLarge = update(id) { j -> Bool in
            guard expectedLength > Int64(truncatingIfNeeded: j.limit) /* Int is 64-bit */, !j.stopAtHeadEnd else { return false }
            j.refusal = .tooLarge
            return true
        } ?? false
        return !tooLarge
    }

    /// Task `id` received `data`; true: the task stops now (over its limit, or past `</head>`).
    func receive(_ id: Int, _ data: Data) -> Bool {
        update(id) { j -> Bool in
            j.data.append(data)
            if j.data.count > j.limit {
                if j.stopAtHeadEnd { j.data = j.data.prefix(j.limit); j.finishedEarly = true } else { j.refusal = .tooLarge }
                return true
            }
            if j.stopAtHeadEnd, let tail = String(data: j.data.suffix(data.count + 8), encoding: .isoLatin1), tail.range(of: "</head>", options: .caseInsensitive) != nil {
                j.finishedEarly = true
                return true
            }
            return false
        } ?? false
    }

    /// Task `id` connected to `addresses` (its transactions' remote addresses): one that is not
    /// public refuses the response (DNS rebinding between our resolution and URLSession's).
    func connected(_ id: Int, to addresses: [String]) {
        guard let bad = addresses.first(where: { !LinkGuard.isPublicAddress($0) && !LinkGuard.isTestAddress($0) }) else { return }
        update(id) { j in j.refusal = j.refusal ?? .connectedTo(bad) }
    }

    /// Task `id` ended with `error` and `response`: its `done` runs once, with the first refusal,
    /// the network error (a stop of our own is not one), a non-2xx status or the data.
    func complete(_ id: Int, error: Error?, response: URLResponse?) {
        guard let j = state.withLock({ $0.jobs.removeValue(forKey: id) }) else { return }
        if let r = j.refusal { j.done(.failure(r)); return }
        if let error, !j.finishedEarly { j.done(.failure(.network(String(describing: (error as NSError).code)))); return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { j.done(.failure(.network("HTTP \(http.statusCode)"))); return }
        j.done(.success(Result(data: j.data, url: response?.url ?? j.url)))
    }

    /// Changes task `id`'s job in place (nil: no such job). The job is moved out and back, so its
    /// data buffer is not copied.
    @discardableResult
    private func update<R: Sendable>(_ id: Int, _ body: @Sendable (inout Job) -> R) -> R? {
        state.withLock { s in
            guard var j = s.jobs.removeValue(forKey: id) else { return nil }
            defer { s.jobs[id] = j }
            return body(&j)
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let next = request.url, let follow = redirect(task.taskIdentifier, to: next) else { completionHandler(nil); return }
        guard follow else { completionHandler(nil); task.cancel(); return }
        var r = request; r.httpShouldHandleCookies = false
        completionHandler(r)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)   // never send credentials
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(respond(dataTask.taskIdentifier, expectedLength: response.expectedContentLength) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if receive(dataTask.taskIdentifier, data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        connected(task.taskIdentifier, to: metrics.transactionMetrics.compactMap(\.remoteAddress))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        complete(task.taskIdentifier, error: error, response: task.response)
    }
}
