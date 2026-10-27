public import AppKit
public import CmuxNextCompatAppKit
public import Foundation
public import CmuxNextRemoteFetch

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
///
/// Its ``MemoryConsumer`` calls scale how many icons each profile keeps (``entriesPerProfile`` at
/// 100 %, none at 0 %), as Chrome's caches follow `base/memory_coordinator/memory_consumer.h`. It does
/// not register itself: `TabFaviconStore` holds the same decoded images for the tab strips, so that
/// store registers "browser-favicons" for both caches and drives these calls (`memoryBrowserCaches`).
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

    /// One kept icon and its decoded pixels, counted once when it is kept.
    private struct Cached {
        let image: NSImage
        let bytes: Int
    }

    private var fetcher: GuardedRemoteFetch
    private var caches: [BrowserProfileID: LRUCache<URL, Cached>] = [:]
    /// The decoded bytes and the count of every kept icon, updated on every keep and drop.
    private var keptBytes = 0
    private var keptCount = 0
    /// The limit `TabFaviconStore` passed on last (100 % until the consumer registers).
    private(set) var memoryLimit = MemoryLimit.default
    private var inFlight: [Key: Task<NSImage?, Never>] = [:]

    /// A loader that fetches nothing until ``useResolver(_:)``.
    public init() {
        fetcher = GuardedRemoteFetch(
            maximumBytes: Self.maximumBytes, timeout: .seconds(30), accept: GuardedRemoteFetch.imageAccept,
            resolver: UnwiredRemoteResolver()
        )
    }

    /// Gives the fetch the App's resolver (`SystemRemoteResolver` on its lanes); AppServices wires ``shared``.
    public func useResolver(_ resolver: any RemoteAddressResolving) {
        fetcher.resolver = resolver
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
        caches[profile]?.value(for: url)?.image
    }

    /// Whether `profile` keeps an icon for `url`, without marking it used.
    public func keepsFavicon(at url: URL, profile: BrowserProfileID) -> Bool {
        caches[profile]?.peek(url) != nil
    }

    public func favicon(at url: URL, profile: BrowserProfileID) async -> NSImage? {
        guard GuardedRemoteFetch.allows(url) else { return nil }
        if let cached = caches[profile]?.value(for: url) { return cached.image }
        let key = Key(profile: profile, url: url)
        if let task = inFlight[key] { return await task.value }
        let fetcher = fetcher
        // Fetch and decode off the main thread (an ICO or SVG decode is not free).
        let task = Task.detached(priority: Task.currentPriority) { () -> NSImage? in
            guard case .success(let response) = await fetcher.fetch(url) else { return nil }
            return Self.decode(response.body)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { keep(image, at: url, profile: profile) }
        return image
    }

    /// Keeps an icon a tab's engine fetched itself (a Chromium tab's own request context,
    /// cx-d0d.8), decoded and capped as a fetch here is, so every reader of `url` for
    /// `profile` gets it without a second, cookieless fetch. Nil when it does not decode.
    public func store(_ data: Data, at url: URL, profile: BrowserProfileID) -> NSImage? {
        guard let image = Self.decode(data) else { return nil }
        keep(image, at: url, profile: profile)
        return image
    }

    /// Drops every icon cached for `profile` (a profile deleted, an
    /// incognito session ended).
    public func forget(profile: BrowserProfileID) {
        guard var cache = caches.removeValue(forKey: profile) else { return }
        while let dropped = cache.removeLeastRecentlyUsed() { didDrop(dropped) }
    }

    /// How many icons each profile may keep now: ``entriesPerProfile`` scaled by ``memoryLimit``.
    var entriesPerProfileLimit: Int { memoryLimit.scale(Self.entriesPerProfile) }

    /// Keeps `image` as `profile`'s most recent icon for `url`; past the limit the least recently
    /// used go (at limit 0, `image` itself).
    private func keep(_ image: NSImage, at url: URL, profile: BrowserProfileID) {
        let entry = Cached(image: image, bytes: Self.decodedBytes(image))
        keptBytes += entry.bytes
        keptCount += 1
        let limit = entriesPerProfileLimit
        for dropped in caches[profile, default: LRUCache(capacity: Self.entriesPerProfile, limit: limit)].set(entry, for: url) {
            didDrop(dropped)
        }
    }

    private func didDrop(_ entry: Cached) {
        keptBytes -= entry.bytes
        keptCount -= 1
    }

    /// The pixels behind a decoded icon (``decode(_:)`` makes one representation of at most
    /// ``maximumPixels`` square), 4 bytes each; read from the representation's size, no draw.
    private static func decodedBytes(_ image: NSImage) -> Int {
        image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
    }

    /// Decodes an icon file (PNG, ICO, SVG, ...) and redraws its best
    /// representation at most ``maximumPixels`` square. The parse and the
    /// redraw, which decodes the pixels, are one checked CPU call
    /// (``blockingNSImage(_:fileID:line:render:)``), so a large icon decoded
    /// on the main thread (``store(_:at:profile:)``) is timed where it runs.
    nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let image = blockingNSImage(data, render: redrawn) else { return nil }
        // 16 pt wide (a favicon's size) with up to 4x pixels behind it.
        let points = CGFloat(16) / CGFloat(max(image.width, image.height))
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) * points, height: CGFloat(image.height) * points))
    }

    /// `source`'s best representation for ``maximumPixels`` square, drawn into
    /// a bitmap of at most that size; nil when it is empty or does not draw.
    private nonisolated static func redrawn(_ source: NSImage) -> CGImage? {
        guard source.size.width > 0, source.size.height > 0 else { return nil }
        let side = CGFloat(maximumPixels)
        var proposed = CGRect(x: 0, y: 0, width: side, height: side)
        // SAFETY: `proposed` is a local rect, live for the call; AppKit reads it and may write
        // the rect it chose back into it, nothing else.
        guard let best = unsafe source.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        let scale = min(1, side / CGFloat(max(best.width, best.height)))
        let width = max(1, Int((CGFloat(best.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(best.height) * scale).rounded()))
        guard let context = CGContext.ownedBitmap(width: width, height: height,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(best, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

}

extension BrowserFaviconLoader: MemoryConsumer {
    /// Lowers or raises each profile's cap to `limit` of ``entriesPerProfile``. Frees nothing: a new
    /// icon past the cap pushes the least recently used out.
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        memoryLimit = limit
        let entries = entriesPerProfileLimit
        for profile in Array(caches.keys) { caches[profile]?.setLimit(entries) }
    }

    /// Drops each profile's least recently used icons down to the slice's limit, one at a time until
    /// the slice expires; a profile left with none goes too.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        for profile in Array(caches.keys) {
            while caches[profile]?.isOverLimit == true {
                if slice.isExpired { return .more }
                if let dropped = caches[profile]?.removeLeastRecentlyUsed() { didDrop(dropped) }
            }
            if caches[profile]?.count == 0 { caches[profile] = nil }
        }
        return .done
    }

    /// The kept icons' decoded pixels, from two counters.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: keptBytes, entries: keptCount)
    }
}
