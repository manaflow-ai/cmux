public import Foundation

/// Implements the REPL's cookie-bearing `fetch`.
///
/// Requests carry the attached tab's cookies, read through the driver's
/// `cookies.get`, and `Set-Cookie` responses are written back with
/// `cookies.set`, so a download fetched from the REPL behaves like one the tab
/// made. The URL session itself stores no cookies; each redirect hop gets the
/// cookies for its own URL instead of inheriting the first hop's header.
///
/// `credentials` follows the Fetch standard's values: `include` (the
/// default, cookies for every URL), `same-origin` (only for URLs on the
/// requesting page's origin) and `omit` (none sent, none stored). The
/// session's domain policy is checked for the first URL, for every
/// redirect hop and for the URL the response came from (an HSTS upgrade
/// moves a request without a redirect hop), and an `http` URL whose
/// `https` form it blocks is refused, first or as a hop, since that
/// upgrade takes the request along before the delegate hears of it. The
/// first URL and each hop are judged again against the current policy in
/// the step that sends them, after their cookies were read. A body larger than `maxBodyBytes` fails the fetch, and so
/// does a body that would take the bodies all of the fetcher's requests
/// hold at once past its `BrowserReplFetchBudget`. A fetch that has not
/// finished after `resourceTimeout` fails, so a body that never ends (an
/// event stream) cannot hold its connection for good.
public final class BrowserReplFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// The largest response body a fetch returns, 64 MiB.
    public static let defaultMaxBodyBytes = 64 << 20

    /// The largest request body a fetch sends, 64 MiB.
    public static let maxRequestBodyBytes = 64 << 20

    /// Why `requestJSON` (the host contract's fetch request) is refused
    /// before it is parsed, or nil: its body could not decode to at most
    /// ``maxRequestBodyBytes`` bytes (Base64 is 4 characters per 3 bytes;
    /// 1 MiB is left for the URL and headers), or its JSON is past the
    /// structure one driver or host call may pass
    /// (``JSONSerialization/browserReplCallStructureRefusal(_:)``), which
    /// no timeout could interrupt the parse of.
    public static func oversizedRequest(_ requestJSON: String) -> BrowserReplDriverError? {
        if requestJSON.utf8.count > maxRequestBodyBytes / 3 * 4 + (1 << 20) {
            return requestBodyTooLarge(atLeast: (requestJSON.utf8.count - (1 << 20)) / 4 * 3)
        }
        guard let reason = JSONSerialization.browserReplCallStructureRefusal(requestJSON) else { return nil }
        return BrowserReplDriverError(code: "invalid", message: "fetch: \(reason)")
    }

    private static func requestBodyTooLarge(atLeast count: Int) -> BrowserReplDriverError {
        BrowserReplDriverError(
            code: "invalid",
            message: "fetch: the request body is more than \(count) bytes; a fetch sends at most 64 MiB"
        )
    }

    /// The most one request sends, its URL, method, headers and decoded body
    /// together: one call's ``BrowserReplResource/requestBytes`` limit of the
    /// session's resource ledger, 64 MiB.
    public static let maxRequestBytes = BrowserReplResourceLimits.standard.each(.requestBytes) ?? maxRequestBodyBytes

    private static func requestTooLarge(atLeast count: Int) -> BrowserReplDriverError {
        BrowserReplDriverError(
            code: "invalid",
            message: "fetch: the request (URL, headers and body) is more than \(count) bytes; a fetch sends at most 64 MiB"
        )
    }

    /// The most response body bytes one fetcher's requests hold at once, 128 MiB.
    public static let defaultMaxBufferedBytes = 128 << 20

    /// The longest a fetch may take from start to its last byte, 10 minutes.
    public static let resourceTimeout: TimeInterval = 600

    private struct TaskInfo {
        let targetID: String?
        let credentials: String
        let origin: String?
        var blocked: String?
        /// The first URL's origin; a hop to another one drops credentials.
        var requestOrigin: String?
        /// Set once a redirect left `requestOrigin`; later hops never get the
        /// credentials back, also one that returns to it.
        var leftOrigin = false
        /// The names of the headers the caller set.
        var callerHeaders: [String] = []
    }

    private let driver: any BrowserReplDriver
    private let publicSuffixes: BrowserReplPublicSuffixList
    private let maxBodyBytes: Int
    /// The bytes of the bodies this fetcher's requests hold, received and
    /// not yet released.
    public let bodyBudget: BrowserReplFetchBudget
    private var session: URLSession!
    private let lock = NSLock()
    private var tasks: [Int: TaskInfo] = [:]
    private var blockReason: (@Sendable (String) -> String?)?
    /// Set by `invalidate()`. A task is created only under `lock` while this
    /// is false, so no task is ever created on an invalidated URL session.
    private var isInvalidated = false

    /// - Parameters:
    ///   - maxBodyBytes: The largest body returned.
    ///   - maxBufferedBytes: The most body bytes all requests hold at once.
    ///   - protocolClasses: URL protocols to try first (tests stub the network).
    ///   - ledger: The session's ledger, which then bounds the bodies
    ///     (``BrowserReplResource/fetchBodyBytes``) instead of `maxBufferedBytes`.
    ///   - publicSuffixes: The list a response's `Set-Cookie` Domain is
    ///     checked against (no cookie on a public suffix is stored).
    public init(
        driver: any BrowserReplDriver,
        maxBodyBytes: Int = defaultMaxBodyBytes,
        maxBufferedBytes: Int = defaultMaxBufferedBytes,
        protocolClasses: [AnyClass]? = nil,
        ledger: BrowserReplResourceLedger? = nil,
        publicSuffixes: BrowserReplPublicSuffixList = .system
    ) {
        self.driver = driver
        self.publicSuffixes = publicSuffixes
        self.maxBodyBytes = ledger?.limits.each(.fetchBodyBytes) ?? maxBodyBytes
        self.bodyBudget = ledger.map(BrowserReplFetchBudget.init(ledger:)) ?? BrowserReplFetchBudget(limit: maxBufferedBytes)
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// The domain policy check: why a URL is blocked, or nil.
    public func setBlockReason(_ check: @escaping @Sendable (String) -> String?) {
        lock.withLock { blockReason = check }
    }

    private func reason(_ url: URL) -> String? {
        // A loopback server cmux runs for local files (the diff viewer's),
        // at every hop, whatever the domain policy.
        if let refusal = BrowserReplFileSandbox.appServedRefusal(url: url.absoluteString, documentOrigin: nil) { return refusal }
        return lock.withLock { blockReason }?(url.absoluteString)
    }

    /// Cancels in-flight requests and breaks the session's strong reference
    /// to this delegate. The fetcher is unusable afterwards.
    public func invalidate() {
        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            return
        }
        isInvalidated = true
        lock.unlock()
        session.invalidateAndCancel()
    }

    private static let closedError = BrowserReplDriverError(code: "closed", message: "fetch: the REPL session was closed")

    /// Performs one request described by the host contract's `requestJSON`:
    /// `{ url, method, headers: [[k, v]], bodyBase64?, targetId?,
    /// credentials?: "include" | "same-origin" | "omit", origin? }`, where
    /// `origin` is the requesting page's origin for `same-origin`.
    public func fetch(requestJSON: String) async -> Result<String, BrowserReplDriverError> {
        let (result, held) = await fetchHoldingBody(requestJSON: requestJSON, onResponse: nil)
        bodyBudget.release(held)
        return result
    }

    /// Performs one request like ``fetch(requestJSON:)``, but the returned
    /// body's bytes stay counted in ``bodyBudget`` until the caller releases
    /// `heldBytes` (once the body has left its hands). `onResponse` runs
    /// once the final response's headers arrived, before its body.
    func fetchHoldingBody(
        requestJSON: String,
        onResponse: (@Sendable () -> Void)?
    ) async -> (result: Result<String, BrowserReplDriverError>, heldBytes: Int) {
        if let refusal = Self.oversizedRequest(requestJSON) { return (.failure(refusal), 0) }
        let request = JSONSerialization.browserReplObject(requestJSON)
        guard let urlString = request["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return (.failure(BrowserReplDriverError(code: "invalid", message: "fetch: only http(s) URLs are supported")), 0)
        }
        if let reason = reason(url) ?? upgradeBlockReason(url) {
            return (.failure(BrowserReplDriverError(code: "blocked", message: "fetch: \(urlString) is blocked: \(reason)")), 0)
        }
        let credentials = request["credentials"] as? String ?? "include"
        guard ["include", "same-origin", "omit"].contains(credentials) else {
            return (.failure(BrowserReplDriverError(code: "invalid", message: "fetch: credentials: expected include, same-origin or omit, got \(credentials)")), 0)
        }
        var info = TaskInfo(
            targetID: request["targetId"] as? String,
            credentials: credentials,
            origin: request["origin"] as? String,
            requestOrigin: Self.origin(of: url)
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = (request["method"] as? String)?.uppercased() ?? "GET"
        // The URL, method and headers count toward the request's size with
        // the decoded body, under one call's request limit of the session's
        // ledger, so the 1 MiB the pre-parse bound leaves for them cannot
        // grow into the body's room.
        var requestBytes = urlString.utf8.count + (urlRequest.httpMethod?.utf8.count ?? 0)
        if let headers = request["headers"] as? [[String]] {
            for pair in headers where pair.count == 2 {
                if let refusal = Self.requestHeaderRefusal(name: pair[0], value: pair[1]) {
                    return (.failure(BrowserReplDriverError(code: "invalid", message: "fetch: \(refusal)")), 0)
                }
                requestBytes += pair[0].utf8.count + pair[1].utf8.count
            }
            guard requestBytes <= Self.maxRequestBytes else {
                return (.failure(Self.requestTooLarge(atLeast: requestBytes)), 0)
            }
            for pair in headers where pair.count == 2 {
                urlRequest.addValue(pair[1], forHTTPHeaderField: pair[0])
                info.callerHeaders.append(pair[0])
            }
        }
        if let body = request["bodyBase64"] as? String {
            // Refused before it is decoded: what it decodes to, less padding.
            let padding = body.utf8.reversed().prefix(2).prefix { $0 == UInt8(ascii: "=") }.count
            let decodedAtLeast = max(0, body.utf8.count / 4 * 3 - padding)
            guard decodedAtLeast <= Self.maxRequestBodyBytes else {
                return (.failure(Self.requestBodyTooLarge(atLeast: decodedAtLeast)), 0)
            }
            guard requestBytes + decodedAtLeast <= Self.maxRequestBytes else {
                return (.failure(Self.requestTooLarge(atLeast: requestBytes + decodedAtLeast)), 0)
            }
            if let data = Data(base64Encoded: body) { urlRequest.httpBody = data }
        }
        if Self.sendsCookies(info, to: url) {
            if urlRequest.value(forHTTPHeaderField: "Cookie") == nil,
               let cookie = await cookieHeader(for: url, targetID: info.targetID) {
                urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        } else {
            // The credentials mode sends no cookies here: not the tab's,
            // and not a Cookie header the caller set (as on redirect hops).
            Self.removeCookieHeaders(from: &urlRequest)
        }

        // The cookie lookup above awaited; the session may have closed since.
        let created: URLSessionDataTask? = lock.withLock {
            guard !isInvalidated else { return nil }
            let task = session.dataTask(with: urlRequest)
            tasks[task.taskIdentifier] = info
            return task
        }
        guard let task = created else { return (.failure(Self.closedError), 0) }
        do {
            let (data, response) = try await data(for: task, onResponse: onResponse) {
                // The policy may have narrowed while the cookies were read.
                self.reason(url) ?? self.upgradeBlockReason(url)
            }
            guard let http = response as? HTTPURLResponse else {
                bodyBudget.release(data.count)
                return (.failure(BrowserReplDriverError(code: "invalid", message: "fetch: non-HTTP response")), 0)
            }
            // Judged when the headers arrived too; checked again before its
            // cookies are stored or its body returned.
            if let effective = http.url, let reason = reason(effective) {
                bodyBudget.release(data.count)
                return (.failure(BrowserReplDriverError(code: "blocked", message: Self.responseBlocked(effective, reason))), 0)
            }
            if Self.sendsCookies(info, to: http.url ?? url) {
                await storeCookies(from: http, targetID: info.targetID)
            }
            let headers: [[String]] = http.allHeaderFields.compactMap { key, value in
                guard let key = key as? String else { return nil }
                return [key.lowercased(), "\(value)"]
            }.sorted { $0[0] < $1[0] }
            let result: [String: Any] = [
                "url": http.url?.absoluteString ?? urlString,
                "status": http.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                "headers": headers,
                "bodyBase64": data.base64EncodedString(),
                "redirected": http.url != url,
            ]
            // The body reaches the session as Base64 in this result, a
            // third larger than the bytes that arrived, and the result is
            // what waits for the session's thread, so it is what is held.
            let json = JSONSerialization.browserReplString(result) ?? "null"
            if let refusal = bodyBudget.resize(from: data.count, to: json.utf8.count) {
                bodyBudget.release(data.count)
                return (.failure(refusal.driverError("fetch")), 0)
            }
            return (.success(json), json.utf8.count)
        } catch let error as BrowserReplDriverError {
            return (.failure(error), 0)
        } catch {
            if lock.withLock({ isInvalidated }) { return (.failure(Self.closedError), 0) }
            if Task.isCancelled, (error as? URLError)?.code == .cancelled { return (.failure(Self.cancelledError), 0) }
            if (error as? URLError)?.code == .timedOut {
                return (.failure(BrowserReplDriverError(
                    code: "timeout",
                    message: "fetch: \(urlString) timed out (a fetch may take at most \(Int(Self.resourceTimeout)) s, and wait at most 60 s for data)"
                )), 0)
            }
            return (.failure(BrowserReplDriverError(code: "invalid", message: "fetch failed: \(error.localizedDescription)")), 0)
        }
    }

    /// Why `url` may not be requested although the policy allows it, or
    /// nil: CFNetwork upgrades an `http` request to a host it has an HSTS
    /// entry for (one a response set, or the preloaded list) to `https`
    /// before it is sent, with its method, headers and body, and tells the
    /// delegate only once the response arrives. So an `http` URL whose
    /// `https` form the policy blocks is never requested, first or as a
    /// redirect hop: its request could reach that blocked origin. HSTS
    /// never applies to an IP address (RFC 6797 section 8.1.1), and a
    /// loopback host's request stays on this machine whichever scheme
    /// takes it, so those are requested.
    private func upgradeBlockReason(_ url: URL) -> String? {
        guard let upgraded = Self.hstsUpgraded(url), let reason = reason(upgraded) else { return nil }
        var https = URLComponents()
        https.scheme = "https"
        https.host = upgraded.host
        https.port = upgraded.port
        let pattern = https.string ?? upgraded.absoluteString
        return "the browser may upgrade it to \(upgraded.absoluteString) (HSTS) before it is sent, with its headers and body, and that URL is blocked: \(reason); allow the https form too (for example \(pattern)) to fetch it"
    }

    /// The URL an HSTS upgrade sends `url` to (RFC 6797 section 8.3: the
    /// scheme becomes `https` and port 80 becomes 443), or nil when no
    /// upgrade applies to it.
    static func hstsUpgraded(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http", let host = BrowserReplHostName.host(of: url),
              !BrowserReplHostName.isIPAddress(host), !BrowserReplHostName.isLoopback(host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let isDefault = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
        if let port = url.port, !isDefault { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    private static func sendsCookies(_ info: TaskInfo, to url: URL) -> Bool {
        switch info.credentials {
        case "omit": return false
        case "same-origin": return info.origin != nil && origin(of: url) == info.origin?.lowercased()
        default: return true
        }
    }

    /// Sends `task` and returns its body and response. `blockReason` is
    /// the domain policy's verdict on the task's URL, judged against the
    /// current policy in the same synchronous step that resumes the task,
    /// so a policy narrowed while the request was prepared (its cookies are
    /// read with an await) blocks it before anything is sent.
    private func data(
        for task: URLSessionDataTask,
        onResponse: (@Sendable () -> Void)?,
        blockReason: @escaping () -> String?
    ) async throws -> (Data, URLResponse) {
        let collector = FetchCollector(limit: maxBodyBytes, budget: bodyBudget, onResponse: onResponse)
        lock.withLock { collectors[task.taskIdentifier] = collector }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                #if DEBUG
                beforeWaiting?(task)
                #endif
                if let reason = blockReason() {
                    forget(task)
                    let url = task.originalRequest?.url?.absoluteString ?? "the URL"
                    collector.fail(BrowserReplDriverError(code: "blocked", message: "fetch: \(url) is blocked: \(reason)"))
                } else if Task.isCancelled {
                    // The cancellation handler already cancelled the URL
                    // session task; it is never sent.
                    forget(task)
                    collector.fail(Self.cancelledError)
                } else {
                    task.resume()
                }
                // The task's completion may already have been delivered (a
                // cancellation of the Swift task cancels it): the collector
                // then holds its result and resumes the fetch at once.
                collector.install(continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    private static let cancelledError = BrowserReplDriverError(
        code: "cancelled",
        message: "fetch: cancelled because the cell that started it timed out or its session ended"
    )

    /// Drops `task`'s state and cancels it before it was resumed; its
    /// completion then finds no collector.
    private func forget(_ task: URLSessionDataTask) {
        lock.withLock {
            collectors[task.taskIdentifier] = nil
            tasks[task.taskIdentifier] = nil
        }
        task.cancel()
    }

    private var collectors: [Int: FetchCollector] = [:]

    #if DEBUG
    /// Test seam: runs in a fetch after its task's collector is registered
    /// and before the fetch waits for the task, so a test can deliver the
    /// task's completion in that window.
    var beforeWaiting: ((URLSessionDataTask) -> Void)?
    #endif

    private func collector(for task: URLSessionTask) -> FetchCollector? {
        lock.lock()
        defer { lock.unlock() }
        return collectors[task.taskIdentifier]
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        // The URL the response came from can differ from every URL the
        // redirect check saw: CFNetwork upgrades a request to `https` for
        // HSTS without a redirect the delegate is told of. A blocked one
        // fails the fetch before its body or cookies are taken.
        if let url = response.url, let reason = reason(url) {
            lock.withLock { tasks[dataTask.taskIdentifier]?.blocked = Self.responseBlocked(url, reason) }
            completionHandler(.cancel)
            return
        }
        collector(for: dataTask)?.responseArrived()
        completionHandler(.allow)
    }

    private static func responseBlocked(_ url: URL, _ reason: String) -> String {
        "fetch: the response came from \(url.absoluteString), which is blocked: \(reason)"
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let collector = collector(for: dataTask) else { return }
        if !collector.append(data) { dataTask.cancel() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let collector = collectors.removeValue(forKey: task.taskIdentifier)
        let info = tasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let blocked = info?.blocked {
            collector?.fail(BrowserReplDriverError(code: "blocked", message: blocked))
        } else {
            collector?.finish(response: task.response, error: error)
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Every hop is checked against the domain policy; a blocked hop fails
        // the fetch instead of returning the redirect.
        if let url = request.url, let reason = reason(url) ?? upgradeBlockReason(url) {
            lock.withLock { tasks[task.taskIdentifier]?.blocked = "fetch: redirect to \(url.absoluteString) is blocked: \(reason)" }
            completionHandler(nil)
            task.cancel()
            return
        }
        let targetOrigin = request.url.flatMap(Self.origin(of:))
        let found: TaskInfo? = lock.withLock {
            guard var info = tasks[task.taskIdentifier] else { return nil }
            if targetOrigin == nil || targetOrigin != info.requestOrigin { info.leftOrigin = true }
            tasks[task.taskIdentifier] = info
            return info
        }
        guard let info = found else {
            completionHandler(nil)
            return
        }
        var redirected = request
        // Credentials meant for one origin never follow a redirect to
        // another (Foundation drops Authorization itself; this does not
        // depend on it). A header's name need not say it carries one, so
        // every header the caller set goes too, except the CORS-safelisted
        // ones a browser lets any page send anywhere.
        if info.leftOrigin {
            Self.removeCredentialHeaders(from: &redirected)
            for name in info.callerHeaders where !Self.isSafelistedHeader(name) {
                redirected.setValue(nil, forHTTPHeaderField: name)
            }
        }
        Task {
            if let from = response.url, Self.sendsCookies(info, to: from) {
                await self.storeCookies(from: response, targetID: info.targetID)
            }
            var next = redirected
            // The Cookie header goes on every hop; cookies for the new URL
            // come from the tab by the credentials rules.
            Self.removeCookieHeaders(from: &next)
            if let url = next.url, Self.sendsCookies(info, to: url),
               let cookie = await self.cookieHeader(for: url, targetID: info.targetID) {
                next.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            // The awaits above let the policy narrow; the hop is judged
            // again against the current policy right before it is followed.
            if let url = next.url, let reason = self.reason(url) ?? self.upgradeBlockReason(url) {
                self.lock.withLock { self.tasks[task.taskIdentifier]?.blocked = "fetch: redirect to \(url.absoluteString) is blocked: \(reason)" }
                completionHandler(nil)
                task.cancel()
                return
            }
            completionHandler(next)
        }
    }

    /// Removes `Cookie` and `Cookie2`, whose cookies the credentials mode
    /// decides.
    static func removeCookieHeaders(from request: inout URLRequest) {
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        request.setValue(nil, forHTTPHeaderField: "Cookie2")
    }

    /// Header names that carry credentials: the standard ones, and custom
    /// ones whose name says so (`X-Api-Key`, `X-Auth-Token`, `X-CSRF-Token`).
    static func isCredentialHeader(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if ["authorization", "proxy-authorization", "cookie", "cookie2"].contains(lowered) { return true }
        return ["auth", "token", "api-key", "apikey", "api_key", "secret", "session", "password", "passwd", "csrf", "xsrf", "credential", "signature"]
            .contains { lowered.contains($0) }
    }

    /// Headers that choose the request's authority or shape its transport,
    /// which the URL (the one the domain policy judged) and URLSession
    /// decide: a caller `Host` would let a request to an allowed URL reach a
    /// blocked virtual host on the same server.
    static let transportHeaderNames: Set<String> = [
        "host", "connection", "keep-alive", "proxy-authorization", "proxy-authenticate",
        "proxy-connection", "transfer-encoding", "te", "trailer", "upgrade", "content-length", "expect",
    ]

    /// Why a caller-supplied request header may not be sent, or nil: its
    /// name (trimmed, any case) is a transport or authority header
    /// (``transportHeaderNames``) or an HTTP/2 pseudo-header (`:authority`),
    /// or its name or value holds CR, LF or NUL. Applies to a REPL fetch,
    /// whose redirect hops reuse the caller's headers, and to the headers
    /// `session.configure({ extraHTTPHeaders })` adds to navigations.
    public static func requestHeaderRefusal(name: String, value: String) -> String? {
        let quoted = name.debugDescription
        if (name + value).unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) {
            return "header \(quoted) is not allowed: a header name or value may not contain CR, LF or NUL"
        }
        let normalized = name.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized.hasPrefix(":") {
            return "header \(quoted) is not allowed: HTTP/2 pseudo-headers come from the URL and method"
        }
        if transportHeaderNames.contains(normalized) {
            return "header \(quoted) is not allowed: the URL and the connection decide it (refused: Host, Connection, Keep-Alive, Proxy-Authorization, Proxy-Authenticate, Proxy-Connection, Transfer-Encoding, TE, Trailer, Upgrade, Content-Length, Expect and :pseudo-headers)"
        }
        return nil
    }

    /// The CORS-safelisted request headers (Fetch standard), which a
    /// cross-origin redirect keeps.
    static func isSafelistedHeader(_ name: String) -> Bool {
        ["accept", "accept-language", "content-language", "content-type", "range"].contains(name.lowercased())
    }

    private static func removeCredentialHeaders(from request: inout URLRequest) {
        for name in (request.allHTTPHeaderFields ?? [:]).keys where isCredentialHeader(name) {
            request.setValue(nil, forHTTPHeaderField: name)
        }
    }

    private func cookieHeader(for url: URL, targetID: String?) async -> String? {
        var params: [String: Any] = ["urls": [url.absoluteString]]
        if let targetID { params["targetId"] = targetID }
        guard case .success(let json) = await driver.call(
            method: "cookies.get",
            paramsJSON: JSONSerialization.browserReplString(params) ?? "{}"
        ), let cookies = JSONSerialization.browserReplValue(json) as? [[String: Any]] else {
            return nil
        }
        let pairs = cookies.compactMap { cookie -> String? in
            guard let name = cookie["name"] as? String, let value = cookie["value"] as? String else { return nil }
            return "\(name)=\(value)"
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    private func storeCookies(from response: HTTPURLResponse, targetID: String?) async {
        guard let url = response.url else { return }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let key = entry.key as? String { result[key] = "\(entry.value)" }
        }
        // Only the cookies a browser would take from this response
        // (HTTPCookie.browserReplMaySet): the parser keeps any Domain.
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .filter { $0.browserReplMaySet(from: url, publicSuffixes: publicSuffixes) }
        guard !cookies.isEmpty else { return }
        let encoded: [[String: Any]] = cookies.map(\.browserReplJSON)
        var params: [String: Any] = ["cookies": encoded]
        if let targetID { params["targetId"] = targetID }
        _ = await driver.call(method: "cookies.set", paramsJSON: JSONSerialization.browserReplString(params) ?? "{}")
    }
}

/// The bytes of response bodies a fetcher's requests hold at once: the
/// ledger's ``BrowserReplResource/fetchBodyBytes``.
///
/// A fetch reserves each chunk as it arrives and fails when the total
/// would pass the limit; the bytes go back when the fetch fails or the
/// holder of its body releases them.
public final class BrowserReplFetchBudget: @unchecked Sendable {
    private let ledger: BrowserReplResourceLedger

    /// A budget of its own, at most `limit` bytes at once.
    public convenience init(limit: Int) {
        self.init(ledger: BrowserReplResourceLedger(limits: .unbounded.with(.fetchBodyBytes, limit)))
    }

    /// The session's budget, in its ledger.
    public init(ledger: BrowserReplResourceLedger) {
        self.ledger = ledger
    }

    /// The most bytes held at once.
    public var limit: Int { ledger.limits[.fetchBodyBytes] }

    /// The bytes held now.
    public var heldBytes: Int { ledger.held(.fetchBodyBytes) }

    /// Takes `count` bytes, or returns why not, taking nothing.
    func reserve(_ count: Int) -> BrowserReplResourceLimitError? {
        // A chunk is never past one body's limit (the fetch checks that).
        ledger.reserve(count, of: .fetchBodyBytes, each: .max)
    }

    /// Replaces `old` held bytes with `new` (a body as the result that
    /// carries it), or returns why not, keeping `old`. One body's limit is
    /// on the bytes that arrived, which the fetch checked.
    func resize(from old: Int, to new: Int) -> BrowserReplResourceLimitError? {
        ledger.resize(.fetchBodyBytes, from: old, to: new, each: .max)
    }

    /// Gives back `count` bytes.
    public func release(_ count: Int) {
        ledger.release(count, of: .fetchBodyBytes)
    }

    static func describe(_ bytes: Int) -> String {
        BrowserReplResourceLimits.describe(bytes, of: .fetchBodyBytes)
    }
}

private final class FetchCollector: @unchecked Sendable {
    private enum Overflow {
        case body
        case budget(BrowserReplResourceLimitError)
    }

    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private let budget: BrowserReplFetchBudget
    private var overflow: Overflow?
    private var onResponse: (@Sendable () -> Void)?
    /// The fetch waiting for the result, once it waits.
    private var continuation: CheckedContinuation<(Data, URLResponse), any Error>?
    /// The result when it came before the fetch waited for it.
    private var outcome: Result<(Data, URLResponse), any Error>?
    /// Set once a result was given; later ones are dropped.
    private var isComplete = false

    init(limit: Int, budget: BrowserReplFetchBudget, onResponse: (@Sendable () -> Void)?) {
        self.limit = limit
        self.budget = budget
        self.onResponse = onResponse
    }

    /// The final response's headers arrived; runs `onResponse` once.
    func responseArrived() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            defer { onResponse = nil }
            return onResponse
        }
        callback?()
    }

    /// Appends a chunk; false once the body is over the limit or the budget.
    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard overflow == nil, !isComplete else { return false }
        if data.count + chunk.count > limit {
            overflow = .body
        } else if let refusal = budget.reserve(chunk.count) {
            overflow = .budget(refusal)
        } else {
            data.append(chunk)
            return true
        }
        budget.release(data.count)
        data = Data()
        return false
    }

    /// The fetch waits on `continuation`: resumed at once when the result
    /// already came, else by the result when it comes. Under one lock with
    /// ``complete(_:)``, so the continuation is resumed exactly once
    /// whichever comes first.
    func install(_ continuation: CheckedContinuation<(Data, URLResponse), any Error>) {
        let ready: Result<(Data, URLResponse), any Error>? = lock.withLock {
            guard let outcome else {
                self.continuation = continuation
                return nil
            }
            self.outcome = nil
            return outcome
        }
        if let ready { continuation.resume(with: ready) }
    }

    /// Gives the fetch its result, the first one only: resumes the waiting
    /// fetch, or keeps the result for ``install(_:)``. A success returns
    /// the body, whose bytes stay held for the caller; a failure gives
    /// them back.
    private func complete(_ result: Result<URLResponse, any Error>) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        let final: Result<(Data, URLResponse), any Error>
        switch result {
        case .success(let response):
            final = .success((data, response))
        case .failure(let error):
            budget.release(data.count)
            final = .failure(error)
        }
        data = Data()
        let waiting = continuation
        continuation = nil
        if waiting == nil { outcome = final }
        lock.unlock()
        waiting?.resume(with: final)
    }

    func fail(_ error: any Error) {
        complete(.failure(error))
    }

    func finish(response: URLResponse?, error: (any Error)?) {
        let overflow = lock.withLock { self.overflow }
        switch overflow {
        case .body?:
            fail(BrowserReplDriverError(
                code: "invalid",
                message: "fetch: the response body is larger than \(BrowserReplFetchBudget.describe(limit)); download it in a tab (page.waitForEvent(\"download\")) instead"
            ))
        case .budget(let refusal)?:
            fail(refusal.driverError("fetch"))
        case nil:
            if let error {
                fail(error)
            } else if let response {
                // The body's bytes stay reserved; the fetcher's caller releases them.
                complete(.success(response))
            } else {
                fail(URLError(.badServerResponse))
            }
        }
    }
}

/// Converts between `HTTPCookie` and the Playwright cookie shape used by the
/// driver's `cookies.get` and `cookies.set`.
extension HTTPCookie {
    /// `{ name, value, domain, path, expires, httpOnly, secure, sameSite }`;
    /// `expires` is seconds since 1970 or `-1` for a session cookie.
    public var browserReplJSON: [String: Any] {
        let sameSite: String
        switch sameSitePolicy {
        case HTTPCookieStringPolicy.sameSiteStrict?: sameSite = "Strict"
        case HTTPCookieStringPolicy.sameSiteLax?: sameSite = "Lax"
        default: sameSite = "None"
        }
        return [
            "name": name,
            "value": value,
            "domain": domain,
            "path": path,
            "expires": expiresDate?.timeIntervalSince1970 ?? -1,
            "httpOnly": isHTTPOnly,
            "secure": isSecure,
            "sameSite": sameSite,
        ]
    }

    /// Builds a cookie from the Playwright shape. `url` may stand in for
    /// `domain` and `path`, as in Playwright's `addCookies`.
    public static func browserRepl(from json: [String: Any]) -> HTTPCookie? {
        guard let name = json["name"] as? String, let value = json["value"] as? String else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value]
        if let urlString = json["url"] as? String, let url = URL(string: urlString), let host = url.host {
            properties[.domain] = host
            properties[.path] = url.path.isEmpty ? "/" : url.path
            if url.scheme == "https" { properties[.secure] = "TRUE" }
        }
        if let domain = json["domain"] as? String { properties[.domain] = domain }
        if let path = json["path"] as? String { properties[.path] = path }
        properties[.path] = properties[.path] ?? "/"
        if let expires = json["expires"] as? Double, expires > 0 {
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }
        if json["secure"] as? Bool == true { properties[.secure] = "TRUE" }
        if json["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch json["sameSite"] as? String {
        case "Strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        case "Lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        default: break
        }
        return HTTPCookie(properties: properties)
    }
}
