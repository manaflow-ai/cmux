public import AppKit
public import CmuxNextCompat

/// The glyph images (``GlyphMask``) chrome labels share, least recently used first out, capped by
/// bytes (p03-rendering-075).
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
    /// pressure and takes it at warning.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    /// The cap at the default limit.
    public let fullCapacityBytes: Int
    /// The cap now: ``fullCapacityBytes`` scaled by the memory coordinator's limit.
    public var capacityBytes: Int { memoryLimit.scale(fullCapacityBytes) }
    /// The limit the memory coordinator gave last.
    public private(set) var memoryLimit: MemoryLimit = .default
    /// The bytes of the images held now.
    public private(set) var totalBytes = 0
    /// How many images labels drew through the cache (each miss draws one; tests, diagnostics).
    public private(set) var rasterizations = 0
    /// The images held now.
    public var count: Int { entries.count }

    // memory: bounded by `capacityBytes` (`totalBytes` never passes it at the default limit; a
    // lowered limit stops growth and the release slices drop down to it).
    private var entries: [Key: Entry] = [:]
    /// The least recently used entry: the next to go.
    private var oldest: Entry?
    /// The most recently used entry.
    private var newest: Entry?
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameter fullCapacityBytes: The cap at the default memory limit.
    public init(fullCapacityBytes: Int = GlyphMaskCache.defaultFullCapacityBytes) {
        self.fullCapacityBytes = max(0, fullCapacityBytes)
    }

    /// Registers with the app's memory coordinator (a later call replaces the registration).
    ///
    /// - Parameter registry: The memory coordinator.
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration = MemoryConsumerRegistration(name: "chrome-glyph-masks", traits: Self.memoryTraits,
                                                        consumer: self, registry: registry)
    }

    /// The image for `key`, drawn by `draw` only when the cache has none, then kept as the most
    /// recent one. An image larger than the cap is returned and not kept; older images go only as
    /// far as the cache would grow past its size before the insert (a lowered cap is the release
    /// slices' work).
    func image(for key: Key, draw: () -> CGImage?) -> CGImage? {
        if let entry = entries[key] {
            touch(entry)
            return entry.image
        }
        rasterizations += 1
        guard let image = draw() else { return nil }
        let bytes = GlyphMask.bytes(of: image)
        let ceiling = max(capacityBytes, totalBytes)
        guard bytes <= capacityBytes else { return image }
        while totalBytes + bytes > ceiling, let victim = oldest { remove(victim) }
        let entry = Entry(key: key, image: image, bytes: bytes)
        entries[key] = entry
        totalBytes += bytes
        link(entry)
        return image
    }

    /// One kept image and its place in the use order.
    private final class Entry {
        let key: Key
        let image: CGImage
        let bytes: Int
        /// The entry used just before this one (nil: this is the oldest).
        weak var older: Entry?
        /// The entry used just after this one (nil: this is the newest).
        weak var newer: Entry?

        init(key: Key, image: CGImage, bytes: Int) {
            self.key = key
            self.image = image
            self.bytes = bytes
        }
    }

    private func touch(_ entry: Entry) {
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

    /// Drops the oldest images until the cache fits the slice's limit, one at a time until the slice
    /// expires. Labels on screen keep their own images (their layers' contents); the next one to
    /// draw that text draws it again.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        let capacity = slice.limit.scale(fullCapacityBytes)
        while totalBytes > capacity, let victim = oldest {
            if slice.isExpired { return .more }
            remove(victim)
        }
        return .done
    }

    /// The images' bytes and count, from counters.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: totalBytes, entries: entries.count)
    }
}
