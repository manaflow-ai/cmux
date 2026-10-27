import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import CoreGraphics

/// Row bitmaps by content, with a bounded cache. The key is the row's kind
/// and height (never its key or the viewport width), so equal content
/// shares one bitmap and a resize redraws only rows whose wrap changed.
///
/// Drawing never runs on the main actor. A miss starts one detached render
/// job per key (`RowArt.render`, a pure function of value types); when it
/// ends, the main actor only stores the image and hands it to the rows that
/// asked for it. Until then a row shows its layers without the bitmap (the
/// outgoing fill is its own layer), as the prototype did during a fast
/// scroll. `prefetch` draws rows near the viewport before they scroll in.
///
/// The host sizes the cache (`maxBytes`, its ``HomeMemoryBudget`` share) and
/// the scene says which rows matter, as cc's tile manager gives memory to
/// tiles by priority bin (cc/tiles/tile_manager.cc, `AssignGpuMemoryToTiles`):
/// the bitmaps of rows on screen (`show`) are never dropped, since their
/// layers hold them anyway; rows near the viewport (`prefetch`) are drawn
/// ahead only while they fit in the budget beside them, and are kept once
/// drawn. A store past `maxBytes` drops the oldest other bitmaps to three
/// quarters of it; `trim(toBytes:)` and `releaseHidden()` give bytes back on
/// request.
@MainActor
final class RowBitmaps { // memory: consumer via HomeRenderMemoryConsumer (CmuxNextHome)
    private struct Key: Hashable {
        var kind: RowSpec.Kind
        var height: CGFloat
        var palette: Int
    }

    private struct Job {
        let id: Int
        let task: Task<Void, Never>
    }

    private var cache: [Key: CGImage] = [:]
    /// The keys of `cache`, oldest stored first.
    private var order: [Key] = []
    /// Pixel bytes of the cached bitmaps.
    private(set) var bytes = 0
    /// The most pixel bytes the cache keeps. Lowering it frees nothing: the
    /// next store drops the oldest bitmaps down to it.
    var maxBytes: Int
    /// The rows on screen: no store or trim drops their bitmaps.
    private var shown: Set<Key> = []
    /// What the bitmaps of the rows on screen hold, estimated for those still drawing.
    private var shownBytes = 0
    /// The rows drawn ahead near the viewport: a store keeps them, a trim on
    /// request drops them after every other bitmap.
    private var near: Set<Key> = []
    /// Render jobs started (tests read it to prove a reflow redraws only changed rows).
    private(set) var renderCount = 0
    /// Bumped when the palette changes; old bitmaps and jobs stop matching.
    private(set) var paletteGeneration = 0
    private(set) var palette: HomePalette
    /// Device pixels per point of the row bitmaps (2 on Mac, 3 on most iPhones).
    private(set) var scale: CGFloat = Canvas.scale

    /// In-flight jobs and the installers waiting for each.
    private var jobs: [Key: Job] = [:]
    private var lastJob = 0
    private var waiters: [Key: [@MainActor (CGImage) -> Void]] = [:]
    private var idleWaiters: [OnceContinuation<Void, OnceContinuationError>] = []

    init(palette: HomePalette, maxBytes: Int) {
        self.palette = palette
        self.maxBytes = max(0, maxBytes)
    }

    func setPalette(_ new: HomePalette) {
        guard new != palette else { return }
        palette = new
        invalidate()
    }

    func setScale(_ new: CGFloat) {
        guard new != scale, new > 0 else { return }
        scale = new
        invalidate()
    }

    /// Old bitmaps and jobs stop matching (palette or scale changed).
    private func invalidate() {
        paletteGeneration += 1
        cache.removeAll()
        order.removeAll()
        bytes = 0
        shown.removeAll()
        shownBytes = 0
        near.removeAll()
        cancelJobs()
    }

    private func cancelJobs() {
        for (_, job) in jobs { job.task.cancel() }
        jobs.removeAll()
        waiters.removeAll()
        resumeIdleWaitersIfDone()
    }

    /// Cached bitmaps.
    var count: Int { cache.count }

    /// The bytes of the cached bitmaps of the rows on screen.
    var shownCachedBytes: Int {
        shown.reduce(0) { $0 + (cache[$1].map(Self.bytes(of:)) ?? 0) }
    }

    /// The rows on screen now, with their bitmap sizes: no store or trim drops
    /// their bitmaps until they leave the screen.
    func show(_ rows: [(spec: RowSpec, size: CGSize)]) {
        shown.removeAll(keepingCapacity: true)
        shownBytes = 0
        for row in rows {
            let key = key(row.spec)
            guard shown.insert(key).inserted else { continue }
            shownBytes += cache[key].map(Self.bytes(of:)) ?? estimatedBytes(row.size)
        }
    }

    /// The rows near the viewport, nearest first. Each one is drawn ahead (or
    /// kept, when cached) while it fits in `maxBytes` beside the rows on
    /// screen; the rest are drawn when they scroll in. So a small budget draws
    /// nothing ahead, and nothing drawn ahead is dropped by the next store and
    /// drawn again.
    func prefetch(_ rows: [(spec: RowSpec, size: CGSize)]) {
        near.removeAll(keepingCapacity: true)
        var room = maxBytes - shownBytes
        for row in rows {
            let key = key(row.spec)
            guard !shown.contains(key), !near.contains(key) else { continue }
            let cost = cache[key].map(Self.bytes(of:)) ?? estimatedBytes(row.size)
            guard cost <= room else { return }
            room -= cost
            near.insert(key)
            if cache[key] == nil { start(key, spec: row.spec, size: row.size) }
        }
    }

    /// Drops the oldest bitmaps until the cache holds at most `target` bytes:
    /// first those of rows away from the viewport, then those drawn ahead. The
    /// rows on screen keep theirs, so the cache can stay above `target`.
    func trim(toBytes target: Int) {
        drop(toBytes: target) { !near.contains($0) }
        drop(toBytes: target) { _ in true }
    }

    /// The transcript is hidden and its rows show nothing: drops every bitmap
    /// and every render job. The rows ask again when the transcript shows.
    func releaseHidden() {
        shown.removeAll()
        shownBytes = 0
        near.removeAll()
        cancelJobs()
        trim(toBytes: 0)
    }

    /// The cached bitmap, or nil after starting (or joining) its render job;
    /// `install` then runs on the main actor with the image.
    func image(for spec: RowSpec, size: CGSize, install: @escaping @MainActor (CGImage) -> Void) -> CGImage? {
        let key = key(spec)
        if let hit = cache[key] { return hit }
        waiters[key, default: []].append(install)
        start(key, spec: spec, size: size)
        return nil
    }

    /// True while a render job runs.
    var isRendering: Bool { !jobs.isEmpty }

    /// Returns when no render job runs (tests and capture tools), or when its waiter is dropped.
    func settled() async {
        guard isRendering else { return }
        _ = try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in
            idleWaiters.append(waiter)
        }
    }

    private func key(_ spec: RowSpec) -> Key { Key(kind: spec.kind, height: spec.height, palette: paletteGeneration) }

    private func start(_ key: Key, spec: RowSpec, size: CGSize) {
        guard jobs[key] == nil else { return }
        renderCount += 1
        lastJob += 1
        let id = lastJob
        let palette = self.palette
        let scale = self.scale
        // task-owner: kept in `jobs` until it installs; cancelled on a palette change or a hide.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let image = RowArt.render(spec, palette: palette, size: size, scale: scale)
            await self?.finish(key, job: id, image)
        }
        jobs[key] = Job(id: id, task: task)
    }

    private func finish(_ key: Key, job id: Int, _ image: CGImage?) {
        // A cancelled job no longer owns its key; a later job for the same key may.
        guard jobs[key]?.id == id else { return }
        jobs[key] = nil
        let installers = waiters.removeValue(forKey: key) ?? []
        if let image {
            store(key, image)
            for install in installers { install(image) }
        }
        resumeIdleWaitersIfDone()
    }

    private func resumeIdleWaitersIfDone() {
        guard jobs.isEmpty, !idleWaiters.isEmpty else { return }
        let resumed = idleWaiters
        idleWaiters.removeAll()
        for c in resumed { c.resume(returning: ()) }
    }

    private func store(_ key: Key, _ image: CGImage) {
        guard cache[key] == nil else { return }
        cache[key] = image
        order.append(key)
        bytes += Self.bytes(of: image)
        guard bytes > maxBytes else { return }
        drop(toBytes: maxBytes / 4 * 3) { !near.contains($0) }
    }

    /// Drops the oldest bitmaps that `droppable` allows, never one on screen,
    /// until the cache holds at most `target` bytes.
    private func drop(toBytes target: Int, where droppable: (Key) -> Bool) {
        guard bytes > target else { return }
        var kept: [Key] = []
        var n = 0
        while n < order.count, bytes > target {
            if let key = order[checked: n] {
                if shown.contains(key) || !droppable(key) {
                    kept.append(key)
                } else if let old = cache.removeValue(forKey: key) {
                    bytes -= Self.bytes(of: old)
                }
            }
            n += 1
        }
        order.replaceSubrange(0..<n, with: kept)
    }

    private static func bytes(of image: CGImage) -> Int { image.bytesPerRow * image.height }

    /// What a bitmap of `size` points holds once drawn: 4 bytes per device pixel.
    private func estimatedBytes(_ size: CGSize) -> Int {
        let width = (max(0, size.width) * scale).rounded(.up)
        let height = (max(0, size.height) * scale).rounded(.up)
        return CrashGuard.int(Double(width) * Double(height) * 4, in: 0...(Int.max / 2))
    }
}
