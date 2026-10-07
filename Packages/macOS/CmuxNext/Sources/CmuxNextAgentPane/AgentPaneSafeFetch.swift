import Foundation
import Synchronization

/// Fetches a reply's web image for the page, which has no network of its own (CSP
/// `connect-src 'none'`, `img-src data:`). The URL is untrusted reply text, so the fetch follows
/// the network rules of decision D5: https only; the host must resolve, and every address it
/// resolves to must be public (``AgentPaneNetworkRules``), checked again on each redirect (at
/// most ``maximumRedirects``); the address the connection really used must be public too, or
/// the body is dropped (a DNS rebinding between the check and the connect); at most
/// ``maximumBytes`` and ``timeout``; an ephemeral session with no cookies, no cache, no
/// credentials, no proxy and no referrer.
protocol AgentPaneImageFetching: Sendable {
    func fetch(_ url: URL) async -> Result<Data, AgentPaneReplyError>
}

nonisolated struct AgentPaneSafeFetch: AgentPaneImageFetching {
    static let maximumBytes = 10 << 20
    static let maximumRedirects = 3
    static let timeout: TimeInterval = 10

    /// Whether a host may be reached; tests replace it.
    var hostCheck: @Sendable (String) async -> Bool = { await AgentPaneNetworkRules.resolvesPublicly($0) }
    /// Whether the addresses the connections used (one per transaction, nil when unknown) may be
    /// reached: every one known and public. Tests replace it.
    var addressesCheck: @Sendable ([String?]) -> Bool = { addresses in
        !addresses.isEmpty && addresses.allSatisfy { $0.map(AgentPaneNetworkRules.isPublic) ?? false }
    }
    /// The session configuration; tests add a stub protocol.
    var makeConfiguration: @Sendable () -> URLSessionConfiguration = { AgentPaneSafeFetch.configuration() }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A proxy would make the connected address the proxy's, and the check meaningless.
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    /// Whether `url` may be fetched at all, before any network: https, a host, no user info.
    static func isFetchable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && !(url.host(percentEncoded: false) ?? "").isEmpty
    }

    func fetch(_ url: URL) async -> Result<Data, AgentPaneReplyError> {
        guard Self.isFetchable(url), let host = url.host(percentEncoded: false) else { return .failure(.imageRefused) }
        guard await hostCheck(host) else { return .failure(.imageRefused) }
        let load = AgentPaneSafeLoad(fetch: self)
        let session = URLSession(configuration: makeConfiguration(), delegate: load, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return await withTaskCancellationHandler {
            await load.run(request, session: session)
        } onCancel: {
            load.cancel()
        }
    }
}

/// One fetch: the redirect and address checks, and the size cap, chunk by chunk.
private nonisolated final class AgentPaneSafeLoad: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var data = Data()
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Result<Data, AgentPaneReplyError>, Never>?
        var redirects = 0
        var cancelled = false
        /// The error the delegate chose (it wins over the transfer's own).
        var refusal: AgentPaneReplyError?
        var completed = false
        var metricsSeen = false
        var addressPublic = false
    }

    private let fetch: AgentPaneSafeFetch
    private let state = Mutex(State())

    init(fetch: AgentPaneSafeFetch) { self.fetch = fetch }

    func run(_ request: URLRequest, session: URLSession) async -> Result<Data, AgentPaneReplyError> {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            let cancelled = state.withLock { state -> Bool in
                state.continuation = continuation
                state.task = task
                return state.cancelled
            }
            if cancelled { finish(.failure(.imageFailed)) } else { task.resume() }
        }
    }

    func cancel() {
        let task = state.withLock { state -> URLSessionDataTask? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }

    private func refuse(_ task: URLSessionTask, _ error: AgentPaneReplyError) {
        state.withLock { if $0.refusal == nil { $0.refusal = error } }
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let count = state.withLock { state -> Int in
            state.redirects += 1
            return state.redirects
        }
        guard count <= AgentPaneSafeFetch.maximumRedirects, let url = request.url, AgentPaneSafeFetch.isFetchable(url),
              let host = url.host(percentEncoded: false) else {
            refuse(task, .imageRefused)
            return completionHandler(nil)
        }
        let check = fetch.hostCheck
        // task-owner: one redirect check; the task waits for its answer
        Task {
            if await check(host) {
                var next = request
                next.httpShouldHandleCookies = false
                next.setValue(nil, forHTTPHeaderField: "Referer")
                completionHandler(next)
            } else {
                self.refuse(task, .imageRefused)
                completionHandler(nil)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Server trust takes the system's evaluation; any credential request is refused.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), response.expectedContentLength <= Int64(AgentPaneSafeFetch.maximumBytes) else {
            state.withLock { if $0.refusal == nil { $0.refusal = .imageFailed } }
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = state.withLock { state -> Bool in
            state.data.append(data)
            return state.data.count > AgentPaneSafeFetch.maximumBytes
        }
        if over { refuse(dataTask, .imageTooLarge) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // Every transaction (each redirect hop) must have used a public address.
        let allPublic = fetch.addressesCheck(metrics.transactionMetrics.map(\.remoteAddress))
        let result = state.withLock { state -> Result<Data, AgentPaneReplyError>? in
            state.metricsSeen = true
            state.addressPublic = allPublic
            return state.completed ? Self.result(state) : nil
        }
        if let result { finish(result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let result = state.withLock { state -> Result<Data, AgentPaneReplyError>? in
            state.completed = true
            if error != nil, state.refusal == nil { state.refusal = .imageFailed }
            return state.metricsSeen ? Self.result(state) : nil
        }
        if let result { finish(result) }
    }

    private static func result(_ state: State) -> Result<Data, AgentPaneReplyError> {
        if let refusal = state.refusal { return .failure(refusal) }
        guard state.addressPublic else { return .failure(.imageRefused) }
        return .success(state.data)
    }

    /// Resumes the caller once.
    private func finish(_ result: Result<Data, AgentPaneReplyError>) {
        let continuation = state.withLock { state -> CheckedContinuation<Result<Data, AgentPaneReplyError>, Never>? in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: result)
    }
}
