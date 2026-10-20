public import AppKit
public import Foundation
import CmuxNextCompat
import CmuxNextRemoteFetch
import ImageIO

/// Loads favicons for tabs.
public protocol BrowserFaviconLoading: AnyObject {
    /// The favicon at `url` for a page of `profile`, or nil.
    func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage?
}

/// Fetches favicons and keeps a small in-memory LRU per profile.
///
/// The URL comes from the page, and the fetch runs in the app process, so every
/// hop uses ``GuardedRemoteFetch``: HTTPS only, no credentials or local names,
/// one DNS lookup whose complete answer must be public, a connection pinned to
/// a checked address, and the same validation after each redirect. It sends no
/// cookies, credentials, referrer or proxy request, reads at most
/// ``maximumBytes``, and has a short whole-fetch deadline. Each profile has its
/// own cache, so one profile (or an incognito session) never sees another's icons.
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

    private let fetcher: GuardedRemoteFetch
    private var caches: [BrowserProfileID: LRUCache<URL, NSImage>] = [:]
    private var inFlight: [Key: Task<NSImage?, Never>] = [:]

    public init() {
        fetcher = GuardedRemoteFetch(
            maximumBytes: Self.maximumBytes, timeout: .seconds(30), accept: GuardedRemoteFetch.imageAccept
        )
    }

    init(resolver: any RemoteAddressResolving, transport: any RemoteFetchTransport) {
        fetcher = GuardedRemoteFetch(
            maximumBytes: Self.maximumBytes, timeout: .seconds(30), accept: GuardedRemoteFetch.imageAccept,
            resolver: resolver, transport: transport
        )
    }

    /// Compatibility seam for the pre-guard regression test. The supplied URLSession is
    /// intentionally never used: favicon network access always goes through the pinned fetch.
    convenience init(session _: URLSession) { self.init() }

    /// The cached icon, without fetching (nil when not loaded yet).
    public func cachedFavicon(at url: URL, profile: BrowserProfileID) -> NSImage? {
        caches[profile]?.value(for: url)
    }

    public func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage? {
        guard GuardedRemoteFetch.allows(url) else { return nil }
        if let cached = caches[profile]?.value(for: url) { return cached }
        let key = Key(profile: profile, url: url)
        if let task = inFlight[key] { return await task.value }
        let fetcher = fetcher
        // Fetch and decode off the main thread (an ICO or SVG decode is not free).
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            guard case .success(let response) = await fetcher.fetch(url) else { return nil }
            return Self.decode(response.body)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { caches[profile, default: LRUCache(capacity: Self.entriesPerProfile)].set(image, for: url) }
        return image
    }

    /// Keeps an icon a tab's engine fetched itself (a Chromium tab's own request context,
    /// cx-d0d.8), decoded and capped as a fetch here is, so every reader of `url` for
    /// `profile` gets it without a second, cookieless fetch. Nil when it does not decode.
    public func store(_ data: Data, at url: URL, profile: BrowserProfileID) -> NSImage? {
        guard let image = Self.decode(data) else { return nil }
        caches[profile, default: LRUCache(capacity: Self.entriesPerProfile)].set(image, for: url)
        return image
    }

    /// Drops every icon cached for `profile` (a profile deleted, an
    /// incognito session ended).
    public func forget(profile: BrowserProfileID) {
        caches[profile] = nil
    }

    /// Decodes and encodes a bounded favicon for a page's data URL.
    public nonisolated static func png(_ data: Data) -> Data? {
        guard let icon = decode(data), let image = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Raster images use ImageIO's bounded thumbnail decode, before any full-size bitmap exists.
    nonisolated static func decode(_ data: Data) -> NSImage? {
        let side = CGFloat(maximumPixels)
        let best: CGImage
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else { return nil }
            best = thumbnail
        } else {
            // AppKit handles vector formats ImageIO cannot read. Bound their canvas before rasterizing.
            guard let source = NSImage(data: data), source.size.width > 0, source.size.height > 0,
                  source.size.width <= 4096, source.size.height <= 4096 else { return nil }
            var proposed = CGRect(x: 0, y: 0, width: side, height: side)
            guard let image = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
                  image.width <= 4096, image.height <= 4096 else { return nil }
            best = image
        }
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

}
