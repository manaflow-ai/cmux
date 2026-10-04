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
/// session's domain policy is checked for the first URL and for every
/// redirect hop. A body larger than `maxBodyBytes` fails the fetch, and so
/// does a body that would take the bodies all of the fetcher's requests
/// hold at once past its `BrowserReplFetchBudget`. A fetch that has not
/// finished after `resourceTimeout` fails, so a body that never ends (an
/// event stream) cannot hold its connection for good.
public final class BrowserReplFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// The largest response body a fetch returns, 64 MiB.
    public static let defaultMaxBodyBytes = 64 << 20

    /// The largest request body a fetch sends, 64 MiB.
    public static let maxRequestBodyBytes = 64 << 20

    /// Why `requestJSON` (the host contract's fetch request) is refused for
    /// its size before it is parsed, or nil: its body could not decode to
    /// at most ``maxRequestBodyBytes`` bytes (Base64 is 4 characters per 3
    /// bytes; 1 MiB is left for the URL and headers).
    public static func oversizedRequest(_ requestJSON: String) -> BrowserReplDriverError? {
        guard requestJSON.utf8.count > maxRequestBodyBytes / 3 * 4 + (1 << 20) else { return nil }
        return requestBodyTooLarge(atLeast: (requestJSON.utf8.count - (1 << 20)) / 4 * 3)
    }

    private static func requestBodyTooLarge(atLeast count: Int) -> BrowserReplDriverError {
        BrowserReplDriverError(
            code: "invalid",
            message: "fetch: the request body is more than \(count) bytes; a fetch sends at most 64 MiB"
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
    }

    private let driver: any BrowserReplDriver
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
    public init(
        driver: any BrowserReplDriver,
        maxBodyBytes: Int = defaultMaxBodyBytes,
        maxBufferedBytes: Int = defaultMaxBufferedBytes,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.driver = driver
        self.maxBodyBytes = maxBodyBytes
        self.bodyBudget = BrowserReplFetchBudget(limit: maxBufferedBytes)
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
        lock.withLock { blockReason }?(url.absoluteString)
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
        if let reason = reason(url) {
            return (.failure(BrowserReplDriverError(code: "blocked", message: "fetch: \(urlString) is blocked: \(reason)")), 0)
        }
        let credentials = request["credentials"] as? String ?? "include"
        guard ["include", "same-origin", "omit"].contains(credentials) else {
            return (.failure(BrowserReplDriverError(code: "invalid", message: "fetch: credentials: expected include, same-origin or omit, got \(credentials)")), 0)
        }
        let info = TaskInfo(
            targetID: request["targetId"] as? String,
            credentials: credentials,
            origin: request["origin"] as? String,
            requestOrigin: Self.origin(of: url)
        )
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = (request["method"] as? String)?.uppercased() ?? "GET"
        if let headers = request["headers"] as? [[String]] {
            for pair in headers where pair.count == 2 {
                urlRequest.addValue(pair[1], forHTTPHeaderField: pair[0])
            }
        }
        if let body = request["bodyBase64"] as? String {
            // Refused before it is decoded: what it decodes to, less padding.
            let padding = body.utf8.reversed().prefix(2).prefix { $0 == UInt8(ascii: "=") }.count
            let decodedAtLeast = max(0, body.utf8.count / 4 * 3 - padding)
            guard decodedAtLeast <= Self.maxRequestBodyBytes else {
                return (.failure(Self.requestBodyTooLarge(atLeast: decodedAtLeast)), 0)
            }
            if let data = Data(base64Encoded: body) { urlRequest.httpBody = data }
        }
        if urlRequest.value(forHTTPHeaderField: "Cookie") == nil, Self.sendsCookies(info, to: url),
           let cookie = await cookieHeader(for: url, targetID: info.targetID) {
            urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
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
            let (data, response) = try await data(for: task, onResponse: onResponse)
            guard let http = response as? HTTPURLResponse else {
                bodyBudget.release(data.count)
                return (.failure(BrowserReplDriverError(code: "invalid", message: "fetch: non-HTTP response")), 0)
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
            return (.success(JSONSerialization.browserReplString(result) ?? "null"), data.count)
        } catch let error as BrowserReplDriverError {
            return (.failure(error), 0)
        } catch {
            if lock.withLock({ isInvalidated }) { return (.failure(Self.closedError), 0) }
            if (error as? URLError)?.code == .timedOut {
                return (.failure(BrowserReplDriverError(
                    code: "timeout",
                    message: "fetch: \(urlString) timed out (a fetch may take at most \(Int(Self.resourceTimeout)) s, and wait at most 60 s for data)"
                )), 0)
            }
            return (.failure(BrowserReplDriverError(code: "invalid", message: "fetch failed: \(error.localizedDescription)")), 0)
        }
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

    private func data(for task: URLSessionDataTask, onResponse: (@Sendable () -> Void)?) async throws -> (Data, URLResponse) {
        let collector = FetchCollector(limit: maxBodyBytes, budget: bodyBudget, onResponse: onResponse)
        lock.withLock { collectors[task.taskIdentifier] = collector }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private var collectors: [Int: FetchCollector] = [:]

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
        collector(for: dataTask)?.responseArrived()
        completionHandler(.allow)
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
        if let url = request.url, let reason = reason(url) {
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
        // As browsers do: credentials meant for one origin never follow a
        // redirect to another (Foundation drops Authorization itself; this
        // does not depend on it).
        if info.leftOrigin { Self.removeCredentialHeaders(from: &redirected) }
        Task {
            if let from = response.url, Self.sendsCookies(info, to: from) {
                await self.storeCookies(from: response, targetID: info.targetID)
            }
            var next = redirected
            // The Cookie header goes on every hop; cookies for the new URL
            // come from the tab by the credentials rules.
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            if let url = next.url, Self.sendsCookies(info, to: url),
               let cookie = await self.cookieHeader(for: url, targetID: info.targetID) {
                next.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            completionHandler(next)
        }
    }

    /// Header names that carry credentials: the standard ones, and custom
    /// ones whose name says so (`X-Api-Key`, `X-Auth-Token`, `X-CSRF-Token`).
    static func isCredentialHeader(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if ["authorization", "proxy-authorization", "cookie", "cookie2"].contains(lowered) { return true }
        return ["auth", "token", "api-key", "apikey", "api_key", "secret", "session", "password", "passwd", "csrf", "xsrf", "credential", "signature"]
            .contains { lowered.contains($0) }
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
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !cookies.isEmpty else { return }
        let encoded: [[String: Any]] = cookies.map(\.browserReplJSON)
        var params: [String: Any] = ["cookies": encoded]
        if let targetID { params["targetId"] = targetID }
        _ = await driver.call(method: "cookies.set", paramsJSON: JSONSerialization.browserReplString(params) ?? "{}")
    }
}

/// The bytes of response bodies a fetcher's requests hold at once.
///
/// A fetch reserves each chunk as it arrives and fails when the total
/// would pass `limit`; the bytes go back when the fetch fails or the
/// holder of its body releases them.
public final class BrowserReplFetchBudget: @unchecked Sendable {
    /// The most bytes held at once.
    public let limit: Int
    private let lock = NSLock()
    private var used = 0

    public init(limit: Int) {
        self.limit = limit
    }

    /// The bytes held now.
    public var heldBytes: Int { lock.withLock { used } }

    /// Takes `count` bytes; false, taking nothing, past the limit.
    func reserve(_ count: Int) -> Bool {
        lock.withLock {
            guard used + count <= limit else { return false }
            used += count
            return true
        }
    }

    /// Gives back `count` bytes.
    public func release(_ count: Int) {
        guard count > 0 else { return }
        lock.withLock { used = max(0, used - count) }
    }

    static func describe(_ bytes: Int) -> String {
        bytes >= 1 << 20 ? "\(bytes >> 20) MiB" : "\(bytes) bytes"
    }
}

private final class FetchCollector: @unchecked Sendable {
    private enum Overflow {
        case body
        case budget
    }

    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private let budget: BrowserReplFetchBudget
    private var overflow: Overflow?
    private var onResponse: (@Sendable () -> Void)?
    var continuation: CheckedContinuation<(Data, URLResponse), any Error>?

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
        guard overflow == nil else { return false }
        if data.count + chunk.count > limit {
            overflow = .body
        } else if !budget.reserve(chunk.count) {
            overflow = .budget
        } else {
            data.append(chunk)
            return true
        }
        budget.release(data.count)
        data = Data()
        return false
    }

    /// Ends the fetch without a body; the bytes it held go back.
    private func takeForFailure() -> CheckedContinuation<(Data, URLResponse), any Error>? {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        budget.release(data.count)
        data = Data()
        lock.unlock()
        return continuation
    }

    func fail(_ error: any Error) {
        takeForFailure()?.resume(throwing: error)
    }

    func finish(response: URLResponse?, error: (any Error)?) {
        lock.lock()
        let overflow = self.overflow
        lock.unlock()
        switch overflow {
        case .body?:
            takeForFailure()?.resume(throwing: BrowserReplDriverError(
                code: "invalid",
                message: "fetch: the response body is larger than \(BrowserReplFetchBudget.describe(limit)); download it in a tab (page.waitForEvent(\"download\")) instead"
            ))
        case .budget?:
            takeForFailure()?.resume(throwing: BrowserReplDriverError(
                code: "invalid",
                message: "fetch: the session's fetches would hold more than \(BrowserReplFetchBudget.describe(budget.limit)) of response bodies at once; await some before starting more, or download large files in a tab (page.waitForEvent(\"download\"))"
            ))
        case nil:
            if let error {
                takeForFailure()?.resume(throwing: error)
            } else if let response {
                // The body's bytes stay reserved; the fetcher's caller releases them.
                lock.lock()
                let continuation = self.continuation
                self.continuation = nil
                let body = data
                lock.unlock()
                continuation?.resume(returning: (body, response))
            } else {
                takeForFailure()?.resume(throwing: URLError(.badServerResponse))
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
