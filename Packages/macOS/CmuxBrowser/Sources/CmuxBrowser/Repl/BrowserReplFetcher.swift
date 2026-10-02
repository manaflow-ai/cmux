public import Foundation

/// Implements the REPL's cookie-bearing `fetch`.
///
/// Requests carry the attached tab's cookies, read through the driver's
/// `cookies.get`, and `Set-Cookie` responses are written back with
/// `cookies.set`, so a download fetched from the REPL behaves like one the tab
/// made. The URL session itself stores no cookies; each redirect hop gets the
/// cookies for its own URL instead of inheriting the first hop's header.
public final class BrowserReplFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let driver: any BrowserReplDriver
    private var session: URLSession!
    private let lock = NSLock()
    private var targetIDs: [Int: String] = [:]
    /// Set by `invalidate()`. A task is created only under `lock` while this
    /// is false, so no task is ever created on an invalidated URL session.
    private var isInvalidated = false

    public init(driver: any BrowserReplDriver) {
        self.driver = driver
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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

    /// Performs one request described by the host contract's `requestJSON`.
    public func fetch(requestJSON: String) async -> Result<String, BrowserReplDriverError> {
        let request = JSONSerialization.browserReplObject(requestJSON)
        guard let urlString = request["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure(BrowserReplDriverError(code: "invalid", message: "fetch: only http(s) URLs are supported"))
        }
        let targetID = request["targetId"] as? String
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
        if urlRequest.value(forHTTPHeaderField: "Cookie") == nil,
           let cookie = await cookieHeader(for: url, targetID: targetID) {
            urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        // The cookie lookup above awaited; the session may have closed since.
        let created: URLSessionDataTask? = lock.withLock {
            guard !isInvalidated else { return nil }
            let task = session.dataTask(with: urlRequest)
            targetIDs[task.taskIdentifier] = targetID
            return task
        }
        guard let task = created else { return .failure(Self.closedError) }
        do {
            let (data, response) = try await data(for: task)
            guard let http = response as? HTTPURLResponse else {
                return .failure(BrowserReplDriverError(code: "invalid", message: "fetch: non-HTTP response"))
            }
            await storeCookies(from: http, targetID: targetID)
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
        } catch {
            if lock.withLock({ isInvalidated }) { return .failure(Self.closedError) }
            return .failure(BrowserReplDriverError(code: "invalid", message: "fetch failed: \(error.localizedDescription)"))
        }
    }

    private func data(for task: URLSessionDataTask) async throws -> (Data, URLResponse) {
        let collector = FetchCollector()
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
        collector(for: dataTask)?.append(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let collector = collectors.removeValue(forKey: task.taskIdentifier)
        targetIDs.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        collector?.finish(response: task.response, error: error)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        let targetID = targetIDs[task.taskIdentifier]
        lock.unlock()
        let redirected = request
        Task {
            await self.storeCookies(from: response, targetID: targetID)
            var next = redirected
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            if let url = next.url, let cookie = await self.cookieHeader(for: url, targetID: targetID) {
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
    var continuation: CheckedContinuation<(Data, URLResponse), any Error>?

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func finish(response: URLResponse?, error: (any Error)?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let body = data
        lock.unlock()
        if let error {
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
