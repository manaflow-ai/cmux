public import AppKit
public import Foundation

/// Loads favicons for tabs.
public protocol BrowserFaviconLoading: AnyObject {
    func favicon(at url: URL) async -> NSImage?
}

/// Fetches favicons with an ephemeral session (no cookies, so profiles do not
/// leak into each other) and caches them in memory by URL.
public final class BrowserFaviconLoader: BrowserFaviconLoading {
    public static let shared = BrowserFaviconLoader()

    private let session: URLSession
    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
        cache.countLimit = 512
    }

    public func favicon(at url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let task = inFlight[url] { return await task.value }
        let session = session
        let task = Task<NSImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                return nil
            }
            return NSImage(data: data)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
