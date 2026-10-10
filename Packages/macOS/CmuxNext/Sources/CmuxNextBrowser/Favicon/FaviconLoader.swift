public import AppKit
public import Foundation
import Synchronization

/// Loads favicons for tabs.
public protocol BrowserFaviconLoading: AnyObject {
    /// The favicon at `url` for a page of `profile`, or nil.
    func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage?
}

/// Fetches favicons and keeps a small in-memory LRU per profile.
///
/// The URL comes from the page, and the fetch runs in the app process, so
/// it is limited to what a favicon needs: http and https only (never a
/// local file), no cookies stored or sent (profiles and sites do not link
/// through it, and a cross-site icon never carries the user's cookies),
/// at most ``maximumBytes`` of body (a larger response is dropped unread),
/// and a short timeout. Each profile has its own cache, so one profile (or
/// an incognito session) never sees another's icons without its own fetch.
/// Decoded icons are redrawn at most ``maximumPixels`` square, so a cached
/// icon costs at most 16 KiB however large the file was.
public final class BrowserFaviconLoader: BrowserFaviconLoading {
    public static let shared = BrowserFaviconLoader()
    /// Largest favicon body read (large touch icons are well under this).
    public nonisolated static let maximumBytes = 1 << 20
    /// Icons per profile kept in memory.
    public static let entriesPerProfile = 64
    /// Side of the largest decoded icon kept (a 16 pt tab icon at 3x is 48).
    public nonisolated static let maximumPixels = 64

    private struct Key: Hashable {
        var profile: BrowserProfileID
        var url: URL
    }

    private let session: URLSession
    private var caches: [BrowserProfileID: LRUCache<URL, NSImage>] = [:]
    private var inFlight: [Key: Task<NSImage?, Never>] = [:]

    public init(session: URLSession = URLSession(configuration: BrowserFaviconLoader.configuration())) {
        self.session = session
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

    /// The cached icon, without fetching (nil when not loaded yet).
    public func cachedFavicon(at url: URL, profile: BrowserProfileID) -> NSImage? {
        caches[profile]?.value(for: url)
    }

    public func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        if let cached = caches[profile]?.value(for: url) { return cached }
        let key = Key(profile: profile, url: url)
        if let task = inFlight[key] { return await task.value }
        let session = session
        // Fetch and decode off the main thread (an ICO or SVG decode is not free).
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            guard let data = await Self.body(of: request, session: session) else { return nil }
            return Self.decode(data)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { caches[profile, default: LRUCache(capacity: Self.entriesPerProfile)].set(image, for: url) }
        return image
    }

    /// Drops every icon cached for `profile` (a profile deleted, an
    /// incognito session ended).
    public func forget(profile: BrowserProfileID) {
        caches[profile] = nil
    }

    /// Decodes an icon file (PNG, ICO, SVG, ...) and redraws its best
    /// representation at most ``maximumPixels`` square.
    nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0 else { return nil }
        let side = CGFloat(maximumPixels)
        var proposed = CGRect(x: 0, y: 0, width: side, height: side)
        guard let best = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        let scale = min(1, side / CGFloat(max(best.width, best.height)))
        let width = max(1, Int((CGFloat(best.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(best.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(best, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        // 16 pt wide (a favicon's size) with up to 4x pixels behind it.
        let points = CGFloat(16) / CGFloat(max(width, height))
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(width) * points, height: CGFloat(height) * points))
    }

    /// The body of a 2xx response, or nil when it is larger than
    /// ``maximumBytes`` (the transfer is cancelled at the limit).
    nonisolated static func body(of request: URLRequest, session: URLSession) async -> Data? {
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
