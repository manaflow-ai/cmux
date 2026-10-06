import Foundation
import Darwin

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

    static func checkURL(_ u: URL) -> Refusal? {
        guard let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .scheme }
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
        return inet_pton(AF_INET, s, &a4) == 1 || inet_pton(AF_INET6, s, &a6) == 1
    }

    /// Every address of a name, numeric (getaddrinfo; IPv4 forms like 2130706433 or 0x7f.1 resolve too).
    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else {
            // AI_ADDRCONFIG drops families without a route; ask again without it.
            hints.ai_flags = 0
            guard getaddrinfo(host, nil, &hints, &res) == 0, res != nil else { return [] }
            defer { freeaddrinfo(res) }
            return numeric(res)
        }
        defer { freeaddrinfo(first) }
        return numeric(first)
    }
    private static func numeric(_ list: UnsafeMutablePointer<addrinfo>?) -> [String] {
        var out: [String] = []
        var p = list
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: buf)
                out.append(s.split(separator: "%").first.map(String.init) ?? s)   // drop a scope id
            }
            p = ai.pointee.ai_next
        }
        return out
    }

    static func isPublicAddress(_ s: String) -> Bool {
        var a4 = in_addr(), a6 = in6_addr()
        if inet_pton(AF_INET, s, &a4) == 1 {
            return isPublicV4(withUnsafeBytes(of: a4.s_addr) { Array($0) })
        }
        if inet_pton(AF_INET6, s, &a6) == 1 {
            return isPublicV6(withUnsafeBytes(of: a6) { Array($0) })
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
        let zero10 = b[0..<10].allSatisfy { $0 == 0 }
        if b.allSatisfy({ $0 == 0 }) { return false }                                    // ::
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return false }               // ::1
        if zero10 && b[10] == 0xff && b[11] == 0xff { return isPublicV4(Array(b[12..<16])) }   // ::ffff:a.b.c.d
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isPublicV4(Array(b[12..<16])) }    // ::a.b.c.d (compatible)
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && b[4..<12].allSatisfy({ $0 == 0 }) {
            return isPublicV4(Array(b[12..<16]))                                          // NAT64 64:ff9b::/96
        }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return false }                         // fe80::/10 link-local
        if b[0] == 0xfe && (b[1] & 0xc0) == 0xc0 { return false }                         // fec0::/10 site-local
        if (b[0] & 0xfe) == 0xfc { return false }                                         // fc00::/7 unique-local
        if b[0] == 0xff { return false }                                                  // multicast
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false }  // 2001:db8::/32 documentation
        if b[0] == 0x01 && b[1..<8].allSatisfy({ $0 == 0 }) { return false }              // 100::/64 discard
        if b[0] == 0x20 && b[1] == 0x02 { return isPublicV4(Array(b[2..<6])) }           // 6to4 2002::/16 embeds v4
        return true
    }
}

/// GETs through LinkGuard: an ephemeral session, redirects re-checked, the
/// connected address re-checked, a size cap. One instance, a background queue.
final class GuardedFetcher: NSObject, URLSessionDataDelegate {
    static let shared = GuardedFetcher()
    struct Result { var data: Data; var url: URL }
    private final class Job {
        var data = Data(); var limit: Int; var stopAtHeadEnd: Bool; var redirects = 0
        var refusal: LinkGuard.Refusal?; var finishedEarly = false
        var done: (Swift.Result<Result, LinkGuard.Refusal>) -> Void
        var url: URL
        init(limit: Int, stopAtHeadEnd: Bool, url: URL, done: @escaping (Swift.Result<Result, LinkGuard.Refusal>) -> Void) {
            self.limit = limit; self.stopAtHeadEnd = stopAtHeadEnd; self.url = url; self.done = done
        }
    }
    private var jobs: [Int: Job] = [:]
    private let lock = NSLock()
    var timeout: TimeInterval = 8
    let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .utility; return q }()
    private lazy var session: URLSession = {
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
        return URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }()

    /// Checks the URL (resolution included), then GETs it. `done` runs on the
    /// fetcher's background queue.
    func get(_ url: URL, limit: Int, html: Bool, done: @escaping (Swift.Result<Result, LinkGuard.Refusal>) -> Void) {
        queue.addOperation { [self] in
            if let r = LinkGuard.check(url) { done(.failure(r)); return }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            req.httpShouldHandleCookies = false
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            req.setValue(html ? "text/html,application/xhtml+xml" : "image/*", forHTTPHeaderField: "Accept")
            let task = session.dataTask(with: req)
            lock.lock(); jobs[task.taskIdentifier] = Job(limit: limit, stopAtHeadEnd: html, url: url, done: done); lock.unlock()
            task.resume()
        }
    }

    private func job(_ t: URLSessionTask) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[t.taskIdentifier] }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let j = job(task), let next = request.url else { completionHandler(nil); return }
        j.redirects += 1
        if j.redirects > LinkGuard.maxRedirects { j.refusal = .redirectLimit; completionHandler(nil); task.cancel(); return }
        if j.url.scheme?.lowercased() == "https" && next.scheme?.lowercased() == "http" { j.refusal = .downgrade; completionHandler(nil); task.cancel(); return }
        if let r = LinkGuard.check(next) { j.refusal = r; completionHandler(nil); task.cancel(); return }
        j.url = next
        var r = request; r.httpShouldHandleCookies = false
        completionHandler(r)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)   // never send credentials
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let j = job(dataTask), response.expectedContentLength > Int64(j.limit), !j.stopAtHeadEnd {
            j.refusal = .tooLarge; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let j = job(dataTask) else { return }
        j.data.append(data)
        if j.data.count > j.limit {
            if j.stopAtHeadEnd { j.data = j.data.prefix(j.limit); j.finishedEarly = true } else { j.refusal = .tooLarge }
            dataTask.cancel(); return
        }
        if j.stopAtHeadEnd, let tail = String(data: j.data.suffix(data.count + 8), encoding: .isoLatin1), tail.range(of: "</head>", options: .caseInsensitive) != nil {
            j.finishedEarly = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let j = job(task) else { return }
        for t in metrics.transactionMetrics {
            if let a = t.remoteAddress, !LinkGuard.isPublicAddress(a) { j.refusal = j.refusal ?? .connectedTo(a) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let j = jobs.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let j else { return }
        if let r = j.refusal { j.done(.failure(r)); return }
        if let error, !j.finishedEarly { j.done(.failure(.network(String(describing: (error as NSError).code)))); return }
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { j.done(.failure(.network("HTTP \(http.statusCode)"))); return }
        j.done(.success(Result(data: j.data, url: task.response?.url ?? j.url)))
    }
}
