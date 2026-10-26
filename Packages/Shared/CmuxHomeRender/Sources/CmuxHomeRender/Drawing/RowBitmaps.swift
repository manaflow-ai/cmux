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
/// The host sizes the cache (`maxBytes`, its ``HomeMemoryBudget`` share):
/// a store past it drops the oldest bitmaps to three quarters of it, and
/// `trim(toBytes:)` and `releaseHidden()` give bytes back on request.
/// Dropping is lossless: a row on screen keeps the image its layer shows,
/// and the next miss draws it again.
@MainActor
final class RowBitmaps { // memory: consumer via HomeRenderMemoryConsumer (CmuxNextHome)
    private struct Key: Hashable {
        var kind: RowSpec.Kind
        var height: CGFloat
        var palette: Int
    }

    private var cache: [Key: CGImage] = [:]
    /// The keys of `cache`, oldest stored first.
    private var order: [Key] = []
    /// Pixel bytes of the cached bitmaps.
    private(set) var bytes = 0
    /// The most pixel bytes the cache keeps. Lowering it frees nothing: the
    /// next store drops the oldest bitmaps down to it.
    var maxBytes: Int
    /// Jobs whose image goes to the rows that asked but is not kept (they
    /// were in flight when the host hid the transcript).
    private var installOnly: Set<Key> = []
    /// Render jobs started (tests read it to prove a reflow redraws only changed rows).
    private(set) var renderCount = 0
    /// Bumped when the palette changes; old bitmaps and jobs stop matching.
    private(set) var paletteGeneration = 0
    private(set) var palette: HomePalette
    /// Device pixels per point of the row bitmaps (2 on Mac, 3 on most iPhones).
    private(set) var scale: CGFloat = Canvas.scale

    /// In-flight jobs and the installers waiting for each.
    private var jobs: [Key: Task<Void, Never>] = [:]
    private var waiters: [Key: [@MainActor (CGImage) -> Void]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

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
        for (_, job) in jobs { job.cancel() }
        jobs.removeAll()
        waiters.removeAll()
        installOnly.removeAll()
        resumeIdleWaitersIfDone()
    }

    /// Cached bitmaps.
    var count: Int { cache.count }

    /// Drops the oldest bitmaps until the cache holds at most `target` bytes.
    func trim(toBytes target: Int) {
        var n = 0
        while n < order.count, bytes > target {
            if let key = order[checked: n], let old = cache.removeValue(forKey: key) { bytes -= Self.bytes(of: old) }
            n += 1
        }
        order.removeFirst(n)
    }

    /// The transcript is hidden: drops every bitmap and every job that only
    /// draws ahead of need; a job a row waits for still installs its image
    /// but does not keep it.
    func releaseHidden() {
        trim(toBytes: 0)
        for key in jobs.keys.filter({ waiters[$0] == nil }) {
            jobs.removeValue(forKey: key)?.cancel()
        }
        installOnly.formUnion(jobs.keys)
        resumeIdleWaitersIfDone()
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

    /// Draws `spec` ahead of need (no installer).
    func prefetch(_ spec: RowSpec, size: CGSize) {
        let key = key(spec)
        guard cache[key] == nil else { return }
        start(key, spec: spec, size: size)
    }

    /// True while a render job runs.
    var isRendering: Bool { !jobs.isEmpty }

    /// Returns when no render job runs (tests and capture tools).
    func settled() async {
        guard isRendering else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func key(_ spec: RowSpec) -> Key { Key(kind: spec.kind, height: spec.height, palette: paletteGeneration) }

    private func start(_ key: Key, spec: RowSpec, size: CGSize) {
        guard jobs[key] == nil else { return }
        renderCount += 1
        let palette = self.palette
        let scale = self.scale
        // task-owner: kept in `jobs` until it installs; cancelled on a palette change.
        jobs[key] = Task.detached(priority: .userInitiated) { [weak self] in
            let image = RowArt.render(spec, palette: palette, size: size, scale: scale)
            await self?.finish(key, image)
        }
    }

    private func finish(_ key: Key, _ image: CGImage?) {
        guard jobs.removeValue(forKey: key) != nil else { return }  // cancelled by a palette change
        let installers = waiters.removeValue(forKey: key) ?? []
        let keep = installOnly.remove(key) == nil
        if let image {
            if keep { store(key, image) }
            for install in installers { install(image) }
        }
        resumeIdleWaitersIfDone()
    }

    private func resumeIdleWaitersIfDone() {
        guard jobs.isEmpty, !idleWaiters.isEmpty else { return }
        let resumed = idleWaiters
        idleWaiters.removeAll()
        for c in resumed { c.resume() }
    }

    private func store(_ key: Key, _ image: CGImage) {
        guard cache[key] == nil else { return }
        cache[key] = image
        order.append(key)
        bytes += Self.bytes(of: image)
        guard bytes > maxBytes else { return }
        trim(toBytes: maxBytes / 4 * 3)
    }

    private static func bytes(of image: CGImage) -> Int { image.bytesPerRow * image.height }
}
