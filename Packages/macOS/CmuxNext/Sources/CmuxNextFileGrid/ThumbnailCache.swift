public import CmuxNextCompat
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
/// It is an ``AsyncMemoryConsumer`` (Chrome's async consumer,
/// base/memory_coordinator/async_memory_consumer_registration.h): its owner
/// registers it with `AsyncMemoryConsumerRegistration`, and the memory
/// limit's calls run on this actor. The limit scales the capacity; a release
/// drops the least recently used thumbnails down to it, and at the critical
/// limit the movie lengths too. A tile asked for after a release renders again.
/// The newest `workingSet` thumbnails, about a screenful, stay at every limit
/// (p07-memory.md section 3.A), so a grid reconfigured under critical pressure
/// shows its tiles without a render each.
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
        /// The image's pixel bytes (bytes per row times height); 0 for none.
        var bytes: Int
    }

    private let generator: any ThumbnailGenerating
    /// Thumbnails kept at the full memory limit.
    private let maxCapacity: Int
    /// The newest thumbnails kept at every limit (at most `maxCapacity`).
    private let workingSet: Int
    /// Thumbnails kept now: `maxCapacity` scaled by the memory limit, never below `workingSet`.
    private var capacity: Int
    private var images: [Key: Entry] = [:]
    /// The pixel bytes of `images`, kept on every insert and removal.
    private var storedBytes = 0
    private var renders: [Key: Task<CGImage?, Never>] = [:]
    private var durations: [String: TimeInterval?] = [:]
    private var clock: UInt64 = 0
    /// How many renders the generator ran (tests read it; a cache hit adds nothing).
    public private(set) var renderCount = 0

    /// Makes a cache.
    ///
    /// - Parameters:
    ///   - capacity: thumbnails kept at the full memory limit (default 600, about four screens of
    ///     large tiles).
    ///   - workingSet: the newest thumbnails kept at every memory limit (default 64, about a
    ///     screenful of tiles).
    ///   - generator: what draws them (default Quick Look).
    public init(capacity: Int = 600, workingSet: Int = 64, generator: any ThumbnailGenerating = QuickLookThumbnailGenerator()) {
        maxCapacity = max(1, capacity)
        self.workingSet = min(max(0, workingSet), maxCapacity)
        self.capacity = maxCapacity
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
        let bytes = image.map(Self.bytes(of:)) ?? 0
        storedBytes += bytes - (images[key]?.bytes ?? 0)
        images[key] = Entry(image: image, used: clock, bytes: bytes)
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
        if durations.count > maxCapacity * 4 { durations.removeAll(keepingCapacity: true) }
        return seconds
    }

    /// The number of thumbnails held.
    public var count: Int { images.count }

    /// The pixel bytes of the thumbnails held.
    public var bytes: Int { storedBytes }

    private func evictIfNeeded() {
        guard images.count > capacity else { return }
        // Drop the oldest eighth at once so a scroll does not evict one per render; the working set stays.
        dropOldest(min(images.count - workingSet, images.count - capacity + capacity / 8))
    }

    /// Drops the `count` least recently used thumbnails.
    private func dropOldest(_ count: Int) {
        guard count > 0 else { return }
        let oldest = images.sorted { $0.value.used < $1.value.used }.prefix(count).map(\.key)
        for key in oldest { storedBytes -= images.removeValue(forKey: key)?.bytes ?? 0 }
    }

    nonisolated private static func bytes(of image: CGImage) -> Int { image.bytesPerRow * image.height }
}

extension ThumbnailCache: AsyncMemoryConsumer {
    /// Large (hundreds of tiles of up to a few hundred KB each), lossless (a tile renders again)
    /// and expensive to make again (a Quick Look render each), so warning pressure leaves it whole
    /// and critical pressure empties it down to its working set.
    nonisolated public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .expensive,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: true
    )

    /// The consumer's name in the memory report.
    nonisolated public static let memoryConsumerName = "file-grid-thumbnails"

    /// Scales how many thumbnails it keeps from now on. Frees nothing: the next render drops the
    /// oldest past the new capacity.
    public func updateMemoryLimit(_ limit: MemoryLimit) -> MemoryUsage? {
        capacity = max(limit.scale(maxCapacity), workingSet)
        return memoryUsage
    }

    /// Drops the least recently used thumbnails down to what `limit` keeps, never below the working
    /// set; at the critical limit every movie length too.
    public func releaseMemory(downTo limit: MemoryLimit) -> MemoryUsage? {
        _ = updateMemoryLimit(limit)
        dropOldest(images.count - capacity)
        if limit.isCritical { durations.removeAll() }
        return memoryUsage
    }

    /// Thumbnail pixel bytes; the entries are the thumbnails and the movie lengths.
    private var memoryUsage: MemoryUsage {
        MemoryUsage(footprintBytes: storedBytes, entries: images.count + durations.count)
    }
}
