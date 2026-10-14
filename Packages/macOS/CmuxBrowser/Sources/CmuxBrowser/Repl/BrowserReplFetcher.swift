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
/// redirect hop. A body larger than `maxBodyBytes` fails the fetch.
public final class BrowserReplFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// The largest response body a fetch returns, 64 MiB.
    public static let defaultMaxBodyBytes = 64 << 20

    private struct TaskInfo {
        let targetID: String?
        let credentials: String
        let origin: String?
        var blocked: String?
    }

    private let driver: any BrowserReplDriver
    private let maxBodyBytes: Int
    private var session: URLSession!
    private let lock = NSLock()
    private var tasks: [Int: TaskInfo] = [:]
    private var blockReason: (@Sendable (String) -> String?)?
    /// Set by `invalidate()`. A task is created only under `lock` while this
    /// is false, so no task is ever created on an invalidated URL session.
    private var isInvalidated = false

    /// - Parameters:
    ///   - maxBodyBytes: The largest body returned.
    ///   - protocolClasses: URL protocols to try first (tests stub the network).
    public init(driver: any BrowserReplDriver, maxBodyBytes: Int = defaultMaxBodyBytes, protocolClasses: [AnyClass]? = nil) {
        self.driver = driver
        self.maxBodyBytes = maxBodyBytes
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
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
        let request = JSONSerialization.browserReplObject(requestJSON)
        guard let urlString = request["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure(BrowserReplDriverError(code: "invalid", message: "fetch: only http(s) URLs are supported"))
        }
        if let reason = reason(url) {
            return .failure(BrowserReplDriverError(code: "blocked", message: "fetch: \(urlString) is blocked: \(reason)"))
        }
        let credentials = request["credentials"] as? String ?? "include"
        guard ["include", "same-origin", "omit"].contains(credentials) else {
            return .failure(BrowserReplDriverError(code: "invalid", message: "fetch: credentials: expected include, same-origin or omit, got \(credentials)"))
        }
        let info = TaskInfo(targetID: request["targetId"] as? String, credentials: credentials, origin: request["origin"] as? String)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = (request["method"] as? String)?.uppercased() ?? "GET"
        if let headers = request["headers"] as? [[String]] {
            for pair in headers where pair.count == 2 {
                urlRequest.addValue(pair[1], forHTTPHeaderField: pair[0])
            }
        }
        if let body = request["bodyBase64"] as? String, let data = Data(base64Encoded: body) {
            urlRequest.httpBody = data
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
        guard let task = created else { return .failure(Self.closedError) }
        do {
            let (data, response) = try await data(for: task)
            guard let http = response as? HTTPURLResponse else {
                return .failure(BrowserReplDriverError(code: "invalid", message: "fetch: non-HTTP response"))
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
            return .success(JSONSerialization.browserReplString(result) ?? "null")
        } catch let error as BrowserReplDriverError {
            return .failure(error)
        } catch {
            if lock.withLock({ isInvalidated }) { return .failure(Self.closedError) }
            return .failure(BrowserReplDriverError(code: "invalid", message: "fetch failed: \(error.localizedDescription)"))
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

    private func data(for task: URLSessionDataTask) async throws -> (Data, URLResponse) {
        let collector = FetchCollector(limit: maxBodyBytes)
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
        guard let info = lock.withLock({ tasks[task.taskIdentifier] }) else {
            completionHandler(nil)
            return
        }
        let redirected = request
        Task {
            if let from = response.url, Self.sendsCookies(info, to: from) {
                await self.storeCookies(from: response, targetID: info.targetID)
            }
            var next = redirected
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            if let url = next.url, Self.sendsCookies(info, to: url),
               let cookie = await self.cookieHeader(for: url, targetID: info.targetID) {
                next.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            completionHandler(next)
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

private final class FetchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private var tooLarge = false
    var continuation: CheckedContinuation<(Data, URLResponse), any Error>?

    init(limit: Int) {
        self.limit = limit
    }

    /// Appends a chunk; false once the body is over the limit.
    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !tooLarge else { return false }
        if data.count + chunk.count > limit {
            tooLarge = true
            data = Data()
            return false
        }
        data.append(chunk)
        return true
    }

    func fail(_ error: any Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func finish(response: URLResponse?, error: (any Error)?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let body = data
        let tooLarge = self.tooLarge
        let limit = self.limit
        lock.unlock()
        if tooLarge {
            let mebibytes = limit >= 1 << 20 ? "\(limit >> 20) MiB" : "\(limit) bytes"
            continuation?.resume(throwing: BrowserReplDriverError(
                code: "invalid",
                message: "fetch: the response body is larger than \(mebibytes); download it in a tab (page.waitForEvent(\"download\")) instead"
            ))
        } else if let error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (body, response))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
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
