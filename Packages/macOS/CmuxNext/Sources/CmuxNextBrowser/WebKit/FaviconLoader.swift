public import AppKit
public import Foundation
import Synchronization

/// Loads favicons for tabs.
public protocol BrowserFaviconLoading: AnyObject {
    func favicon(at url: URL) async -> NSImage?
}

/// Fetches favicons and caches them in memory by URL.
///
/// The URL comes from the page, and the fetch runs in the app process, so
/// it is limited to what a favicon needs: http and https only (never a
/// local file), no cookies stored or sent (profiles and sites do not link
/// through it), at most ``maximumBytes`` of body (a larger response is
/// dropped unread), and a short timeout.
public final class BrowserFaviconLoader: BrowserFaviconLoading {
    public static let shared = BrowserFaviconLoader()
    /// Largest favicon body read (large touch icons are well under this).
    public static let maximumBytes = 1 << 20

    private let session: URLSession
    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    public init(session: URLSession = URLSession(configuration: BrowserFaviconLoader.configuration())) {
        self.session = session
        cache.countLimit = 512
    }

    /// Ephemeral, cookieless, uncached, with a short timeout.
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    public func favicon(at url: URL) async -> NSImage? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let task = inFlight[url] { return await task.value }
        let session = session
        let task = Task<NSImage?, Never> {
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            guard let data = await Self.body(of: request, session: session) else { return nil }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// The body of a 2xx response, or nil when it is larger than
    /// ``maximumBytes`` (the transfer is cancelled at the limit).
    static func body(of request: URLRequest, session: URLSession) async -> Data? {
        let limiter = SizeLimitedLoad(limit: maximumBytes)
        return await withTaskCancellationHandler {
            await limiter.run(request, session: session)
        } onCancel: {
            limiter.cancel()
        }
    }
}

/// One data task that collects at most `limit` bytes, chunk by chunk.
private nonisolated final class SizeLimitedLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var data = Data()
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Data?, Never>?
        var cancelled = false
    }

    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) { self.limit = limit }

    func run(_ request: URLRequest, session: URLSession) async -> Data? {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: request)
            task.delegate = self
            let cancelled = state.withLock { state -> Bool in
                state.continuation = continuation
                state.task = task
                return state.cancelled
            }
            if cancelled { finish(nil) } else { task.resume() }
        }
    }

    func cancel() {
        let task = state.withLock { state -> URLSessionDataTask? in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let tooLarge = response.expectedContentLength > Int64(limit)
        guard (200..<300).contains(status), !tooLarge else {
            completionHandler(.cancel)
            return finish(nil)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = state.withLock { state -> Bool in
            state.data.append(data)
            return state.data.count > limit
        }
        if over {
            dataTask.cancel()
            finish(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let data = state.withLock { $0.data }
        finish(error == nil ? data : nil)
    }

    /// Resumes the caller once.
    private func finish(_ result: Data?) {
        let continuation = state.withLock { state -> CheckedContinuation<Data?, Never>? in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: result)
    }
}
