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
@MainActor
final class RowBitmaps {
    private struct Key: Hashable {
        var kind: RowSpec.Kind
        var height: CGFloat
        var palette: Int
    }

    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var bytes = 0
    static let capacity = 500
    static let maxBytes = 96 << 20
    /// Render jobs started (tests read it to prove a reflow redraws only changed rows).
    private(set) var renderCount = 0
    /// Bumped when the palette changes; old bitmaps and jobs stop matching.
    private(set) var paletteGeneration = 0
    private(set) var palette: HomePalette

    /// In-flight jobs and the installers waiting for each.
    private var jobs: [Key: Task<Void, Never>] = [:]
    private var waiters: [Key: [@MainActor (CGImage) -> Void]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(palette: HomePalette) { self.palette = palette }

    func setPalette(_ new: HomePalette) {
        guard new != palette else { return }
        palette = new
        paletteGeneration += 1
        cache.removeAll()
        order.removeAll()
        bytes = 0
        for (_, job) in jobs { job.cancel() }
        jobs.removeAll()
        waiters.removeAll()
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
        // task-owner: kept in `jobs` until it installs; cancelled on a palette change.
        jobs[key] = Task.detached(priority: .userInitiated) { [weak self] in
            let image = RowArt.render(spec, palette: palette, size: size)
            await self?.finish(key, image)
        }
    }

    private func finish(_ key: Key, _ image: CGImage?) {
        guard jobs.removeValue(forKey: key) != nil else { return }  // cancelled by a palette change
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
        for c in resumed { c.resume() }
    }

    private func store(_ key: Key, _ image: CGImage) {
        cache[key] = image
        order.append(key)
        bytes += image.bytesPerRow * image.height
        guard order.count > Self.capacity + 100 || bytes > Self.maxBytes else { return }
        var n = 0
        while n < order.count - 1, order.count - n > Self.capacity || bytes > Self.maxBytes * 3 / 4 {
            if let old = cache.removeValue(forKey: order[n]) { bytes -= old.bytesPerRow * old.height }
            n += 1
        }
        order.removeFirst(n)
    }
}
