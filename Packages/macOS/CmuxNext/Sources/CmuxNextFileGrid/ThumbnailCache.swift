public import CoreGraphics
public import Foundation

/// Thumbnails and movie lengths for grid tiles, made once and kept in a
/// bounded least-recently-used cache.
///
/// Keyed by path, modification date and size, so a rewritten file draws
/// again and an unchanged one never does. Concurrent asks for the same tile
/// share one render. Rendering runs in the injected generator, off the main
/// actor; only tiles a grid shows ask, so a folder of thousands of files
/// renders a screenful.
///
/// ```swift
/// let cache = ThumbnailCache(capacity: 600)
/// let image = await cache.thumbnail(for: item, side: 160, scale: 2)
/// ```
public actor ThumbnailCache {
    private struct Key: Hashable {
        var path: String
        var modified: Date
        var size: Int64
        var pixels: Int
    }

    private struct Entry {
        var image: CGImage?
        var used: UInt64
    }

    private let generator: any ThumbnailGenerating
    private let capacity: Int
    private var images: [Key: Entry] = [:]
    private var renders: [Key: Task<CGImage?, Never>] = [:]
    private var durations: [String: TimeInterval?] = [:]
    private var clock: UInt64 = 0
    /// How many renders the generator ran (tests read it; a cache hit adds nothing).
    public private(set) var renderCount = 0

    /// Makes a cache.
    ///
    /// - Parameters:
    ///   - capacity: thumbnails kept (default 600, about four screens of large tiles).
    ///   - generator: what draws them (default Quick Look).
    public init(capacity: Int = 600, generator: any ThumbnailGenerating = QuickLookThumbnailGenerator()) {
        self.capacity = max(1, capacity)
        self.generator = generator
    }

    /// The tile picture for `item` at this size, rendered on first ask.
    ///
    /// - Parameters:
    ///   - item: the file.
    ///   - side: the tile's side in points.
    ///   - scale: the screen's backing scale.
    /// - Returns: the thumbnail, nil when the system cannot draw one (the grid shows the file's icon).
    public func thumbnail(for item: FileGridItem, side: CGFloat, scale: CGFloat) async -> CGImage? {
        let key = Key(path: item.id, modified: item.modified, size: item.size, pixels: Int((side * scale).rounded()))
        clock += 1
        if let entry = images[key] {
            images[key]?.used = clock
            return entry.image
        }
        if let pending = renders[key] { return await pending.value }
        let generator = generator
        let url = item.url
        let render = Task { await generator.thumbnail(for: url, side: side, scale: scale) }
        renders[key] = render
        renderCount += 1
        let image = await render.value
        renders[key] = nil
        clock += 1
        images[key] = Entry(image: image, used: clock)
        evictIfNeeded()
        return image
    }

    /// The thumbnail already in the cache, without rendering (a tile's first frame).
    ///
    /// - Parameters:
    ///   - item: the file.
    ///   - side: the tile's side in points.
    ///   - scale: the screen's backing scale.
    public func cachedThumbnail(for item: FileGridItem, side: CGFloat, scale: CGFloat) -> CGImage? {
        images[Key(path: item.id, modified: item.modified, size: item.size, pixels: Int((side * scale).rounded()))]?.image
    }

    /// The movie length of `item`, read once per path and date.
    ///
    /// - Parameter item: a movie.
    /// - Returns: seconds, nil for a still or an unreadable movie.
    public func duration(for item: FileGridItem) async -> TimeInterval? {
        guard item.kind == .video else { return nil }
        let key = "\(item.id)\u{0}\(item.modified.timeIntervalSinceReferenceDate)"
        if let known = durations[key] { return known }
        let seconds = await generator.duration(for: item.url)
        durations[key] = seconds
        if durations.count > capacity * 4 { durations.removeAll(keepingCapacity: true) }
        return seconds
    }

    /// Drops every cached thumbnail (memory pressure).
    public func removeAll() {
        images.removeAll()
        durations.removeAll()
    }

    /// The number of thumbnails held.
    public var count: Int { images.count }

    private func evictIfNeeded() {
        guard images.count > capacity else { return }
        // Drop the oldest eighth at once so a scroll does not evict one per render.
        let drop = max(1, images.count - capacity + capacity / 8)
        let oldest = images.sorted { $0.value.used < $1.value.used }.prefix(drop).map(\.key)
        for key in oldest { images[key] = nil }
    }
}
