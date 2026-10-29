public import AppKit
public import CmuxNextCompat

/// The glyph images (``GlyphMask``) chrome labels share, least recently used first out, capped by
/// bytes.
///
/// Labels that show the same text in the same shape, size, scale and stem weight (a sidebar's
/// "Terminal" or "main" rows, a tab strip's titles) draw their glyphs once and share the image.
/// It is Chrome's glyph cache: Skia keeps one byte-limited LRU of glyph strikes keyed by what shapes
/// them (font, size, transform; `third_party/skia/src/core/SkStrikeCache.cpp`), and drops them on
/// memory pressure (`SkGraphics::PurgeFontCache`). cmux keys whole-label images, not glyphs: a
/// label's mask is one layer's contents (``ChromeLabel``), never composed per glyph on main.
///
/// The composition root builds one with `sharedGlyphMasks` on (`AppMemoryConsumers.registerGlyphMasks`)
/// and sets it as the app scope's ``ThemeScope/sharedGlyphMasks``; a label reads its scope's
/// (``ThemeScope/glyphMasks``). Without one a label keeps its own images.
public final class GlyphMaskCache {
    /// What a glyph image shows: the text with its font, its shape, the view's size and scale, and
    /// the stem weight of its ink (``GlyphMask/weight(of:)``). Not its color: the fill layer carries it.
    struct Key: Hashable {
        var text: NSAttributedString
        var shape: LabelText.Shape
        var size: CGSize
        var scale: CGFloat
        var weight: Int

        /// Whether `other` shows the same glyphs in any stem weight.
        func showsSameText(as other: Key) -> Bool {
            var same = other
            same.weight = weight
            return self == same
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(text)
            hasher.combine(size.width)
            hasher.combine(size.height)
            hasher.combine(scale)
            hasher.combine(weight)
        }
    }

    /// The cap at the default memory limit. Skia's glyph cache is 2 MiB of glyphs; a label image is
    /// a whole line (a 200 x 16 pt label at 2x is 50 KiB), so this keeps a few hundred labels.
    nonisolated public static let defaultFullCapacityBytes = 16 << 20

    /// Lossless, memory only, a redraw away and cheap to drop: the coordinator scales it with
    /// pressure and takes it at warning. As every lossless consumer, it keeps its working set (images
    /// used in the last ``MemoryLimit/workingSet``) at any limit, critical included.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    /// The cap at the default limit.
    public let fullCapacityBytes: Int
    /// The cap on idle images now: ``fullCapacityBytes`` scaled by the memory coordinator's limit. The
    /// working set stays on top of it (``MemoryLimit/scale(_:inUse:)``), up to ``fullCapacityBytes``.
    public var capacityBytes: Int { memoryLimit.scale(fullCapacityBytes) }
    /// The limit the memory coordinator gave last.
    public private(set) var memoryLimit: MemoryLimit = .default
    /// The bytes of the images held now.
    public private(set) var totalBytes = 0
    /// How many images labels drew through the cache (each miss draws one; tests, diagnostics).
    public private(set) var rasterizations = 0
    /// The images held now.
    public var count: Int { entries.count }

    // memory: bounded by `fullCapacityBytes` (`totalBytes` never passes it; a lowered limit stops
    // growth past the working set and the release slices drop the idle images down to it).
    private var entries: [Key: Entry] = [:]
    /// The least recently used entry: the next to go.
    private var oldest: Entry?
    /// The most recently used entry.
    private var newest: Entry?
    private var memoryRegistration: MemoryConsumerRegistration?
    /// The time since the cache was made, on its clock.
    private let elapsed: () -> Duration

    /// - Parameters:
    ///   - fullCapacityBytes: The cap at the default memory limit.
    ///   - clock: Times how long a used image stays in the working set; tests pass their own.
    public init(fullCapacityBytes: Int = GlyphMaskCache.defaultFullCapacityBytes,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.fullCapacityBytes = max(0, fullCapacityBytes)
        elapsed = Self.elapsed(on: clock)
    }

    private static func elapsed<C: Clock<Duration>>(on clock: C) -> () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// Registers with the app's memory coordinator (a later call replaces the registration).
    ///
    /// - Parameter registry: The memory coordinator.
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration = MemoryConsumerRegistration(name: "chrome-glyph-masks", traits: Self.memoryTraits,
                                                        consumer: self, registry: registry)
    }

    /// The image for `key`, drawn by `draw` only when the cache has none, then kept as the most
    /// recent one. An image larger than ``fullCapacityBytes`` is returned and not kept. To make room,
    /// idle images go oldest first, only as far as the cache would grow past its size before the
    /// insert or its limit with the working set (a lowered limit is the release slices' work); past
    /// ``fullCapacityBytes`` the oldest goes even in the working set.
    func image(for key: Key, draw: () -> CGImage?) -> CGImage? {
        let now = elapsed()
        if let entry = entries[key] {
            touch(entry, now: now)
            return entry.image
        }
        rasterizations += 1
        guard let image = draw() else { return nil }
        let bytes = GlyphMask.bytes(of: image)
        guard bytes <= fullCapacityBytes else { return image }
        let ceiling = max(limitBytes(at: memoryLimit, now: now, adding: bytes), totalBytes)
        let idleBefore = now - MemoryLimit.workingSet
        while totalBytes + bytes > ceiling, let victim = oldest, victim.usedAt < idleBefore { remove(victim) }
        while totalBytes + bytes > fullCapacityBytes, let victim = oldest { remove(victim) }
        let entry = Entry(key: key, image: image, bytes: bytes, usedAt: now)
        entries[key] = entry
        totalBytes += bytes
        link(entry)
        return image
    }

    /// One kept image, when it was last used and its place in the use order.
    private final class Entry {
        let key: Key
        let image: CGImage
        let bytes: Int
        /// When it was last used, on the cache's clock. The use order is the time order, so every entry
        /// older than an idle one is idle too.
        var usedAt: Duration
        /// The entry used just before this one (nil: this is the oldest).
        weak var older: Entry?
        /// The entry used just after this one (nil: this is the newest).
        weak var newer: Entry?

        init(key: Key, image: CGImage, bytes: Int, usedAt: Duration) {
            self.key = key
            self.image = image
            self.bytes = bytes
            self.usedAt = usedAt
        }
    }

    /// The bytes of the images in the working set at `now`, and the oldest use among them (nil: none).
    private func workingSet(now: Duration) -> (bytes: Int, oldestUse: Duration?) {
        let idleBefore = now - MemoryLimit.workingSet
        var bytes = 0, oldestUse: Duration?
        var entry = newest
        while let current = entry, current.usedAt >= idleBefore {
            bytes += current.bytes
            oldestUse = current.usedAt
            entry = current.older
        }
        return (bytes, oldestUse)
    }

    /// The bytes `limit` lets the cache keep at `now`: the working set (with `adding` more in it) and
    /// the limit's share of the rest. At the default limit that is ``fullCapacityBytes`` (no walk).
    private func limitBytes(at limit: MemoryLimit, now: Duration, adding: Int) -> Int {
        guard limit < .default else { return fullCapacityBytes }
        return limit.scale(fullCapacityBytes, inUse: workingSet(now: now).bytes + adding)
    }

    private func touch(_ entry: Entry, now: Duration) {
        entry.usedAt = now
        guard entry !== newest else { return }
        unlink(entry)
        link(entry)
    }

    /// Makes `entry` the newest.
    private func link(_ entry: Entry) {
        entry.older = newest
        entry.newer = nil
        newest?.newer = entry
        newest = entry
        if oldest == nil { oldest = entry }
    }

    private func unlink(_ entry: Entry) {
        if let older = entry.older { older.newer = entry.newer } else { oldest = entry.newer }
        if let newer = entry.newer { newer.older = entry.older } else { newest = entry.older }
        entry.older = nil
        entry.newer = nil
    }

    private func remove(_ entry: Entry) {
        unlink(entry)
        entries[entry.key] = nil
        totalBytes -= entry.bytes
    }
}

extension GlyphMaskCache: MemoryConsumer {
    /// Keeps the limit: the cap scales with it from the next insert. Frees nothing.
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        memoryLimit = limit
    }

    /// Drops the oldest idle images until the cache fits the slice's limit with its working set on
    /// top (``MemoryLimit/scale(_:inUse:)``), one at a time until the slice expires. Images used in the
    /// last ``MemoryLimit/workingSet`` stay at any limit; while some keep the cache over the plain
    /// limit, it asks to be called again when the oldest of them goes idle.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        let now = elapsed()
        let inUse = workingSet(now: now)
        let capacity = slice.limit.scale(fullCapacityBytes, inUse: inUse.bytes)
        let idleBefore = now - MemoryLimit.workingSet
        while totalBytes > capacity, let victim = oldest, victim.usedAt < idleBefore {
            if slice.isExpired { return .more }
            remove(victim)
        }
        guard totalBytes > slice.limit.scale(fullCapacityBytes), let oldestUse = inUse.oldestUse else { return .done }
        return .finished(keptInUseIdleFor: now - oldestUse)
    }

    /// The images' bytes and count, from counters.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: totalBytes, entries: entries.count)
    }
}
