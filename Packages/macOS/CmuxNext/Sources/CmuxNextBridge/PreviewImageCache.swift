public import CmuxNextCompat
public import CoreGraphics

/// Downscaled tab preview images, least recently used first out, capped by decoded byte size.
///
/// Its full size, ``fullCapacityBytes``, is the owner's share of `SubsystemBudget.imageCacheBytes`
/// (plans/cmux-next/chrome-parity/p07-memory.md, task 058). Registered with the memory coordinator
/// (``registerMemoryConsumer(name:with:)``), it is a memory consumer whose traits say whether its
/// pictures can be taken again (``Contents``), as Chrome's decoded image caches drop their unused
/// decodes on memory pressure (`cc/tiles/software_image_decode_cache.cc` and `gpu_image_decode_cache.cc`,
/// `OnMemoryPressure`). A new limit only lowers ``capacityBytes``: an insert never grows the cache past
/// its size before the insert, and the coordinator's release slices drop the oldest images past the cap,
/// on later frames.
///
/// It keeps ``PurgeablePicture``s that ``picture(of:)`` made from its ``allocator``, so an insert
/// copies no pixels. With feature `purgeableImageCaches` on, a picture is a copy drawn off the main actor into purgeable
/// pages, volatile whenever nothing draws it, so the kernel takes it back under pressure with no call into cmux, as
/// Chrome keeps decoded images in discardable memory; ``image(for:)`` locks a picture for as long as its image lives,
/// and a picture the kernel purged is a miss that leaves the cache, never a blank draw. Off, a picture is the image
/// itself, as before. The memory report splits locked (footprint) bytes from volatile ones.
public final class PreviewImageCache {
    /// What the cache holds, which decides when the memory coordinator takes its images.
    public enum Contents: Sendable {
        /// Pictures the owner takes again on demand (terminal previews): it gives memory back at warning.
        case rebuildable
        /// The only copy of each picture (a hidden page's last frame, which the engine cannot take
        /// again): the coordinator leaves it whole until critical pressure.
        case onlyCopy
    }

    /// Traits of a ``Contents/rebuildable`` cache: lossless, memory only, cheap to rebuild, and it honors
    /// partial limits, so it is managed and gives memory back at warning.
    public static let rebuildableTraits = MemoryConsumerTraits(
        estimatedUsage: .medium,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .cheap,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: true
    )

    /// Traits of an ``Contents/onlyCopy`` cache: lossy and expensive to rebuild, so the coordinator limits
    /// it only at critical pressure, in its last release tier.
    public static let onlyCopyTraits = MemoryConsumerTraits(
        estimatedUsage: .medium,
        dataAccess: .none,
        retention: .lossy,
        recreateCost: .expensive,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: true
    )

    /// The cap at the default limit: the owner's share of the image cache budget.
    public let fullCapacityBytes: Int
    /// The traits it registers with (``Contents``).
    public let memoryTraits: MemoryConsumerTraits
    /// The cap now: ``fullCapacityBytes`` scaled by the memory coordinator's limit.
    public var capacityBytes: Int { memoryLimit.scale(fullCapacityBytes) }
    /// The limit the memory coordinator gave last.
    public private(set) var memoryLimit: MemoryLimit = .default
    public private(set) var totalBytes = 0
    /// Makes its pictures: purgeable pages with `purgeableImageCaches` on, the images themselves otherwise.
    public let allocator: PurgeableAllocator
    /// Its pictures' locked bytes, which readers on any thread move in and out.
    private let ledger = PurgeableLedger()
    private var images: [String: PurgeablePicture] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - fullCapacityBytes: The cap at the default limit (a share of `SubsystemBudget.imageCacheBytes`).
    ///   - contents: Whether its pictures can be taken again.
    ///   - allocator: Makes its pictures: purgeable pages with `purgeableImageCaches` on, the images themselves otherwise.
    public init(fullCapacityBytes: Int, contents: Contents = .rebuildable, allocator: PurgeableAllocator = .resident) {
        self.fullCapacityBytes = max(0, fullCapacityBytes)
        self.allocator = allocator
        switch contents {
        case .rebuildable: memoryTraits = Self.rebuildableTraits
        case .onlyCopy: memoryTraits = Self.onlyCopyTraits
        }
    }

    public var count: Int { images.count }

    /// Registers with the app's memory coordinator (once; a later call replaces the registration).
    ///
    /// - Parameters:
    ///   - name: The consumer's name in the memory report (`preview-images`, `page-thumbnails`).
    ///   - registry: The memory coordinator.
    public func registerMemoryConsumer(name: String, with registry: any MemoryConsumerRegistry) {
        memoryRegistration = MemoryConsumerRegistration(name: name, traits: memoryTraits, consumer: self, registry: registry)
    }

    /// The picture for `key`, now the most recent one, its pixels locked while the image lives (no pixel copy).
    /// Nil when there is none or the kernel purged its pages: a purged picture leaves the cache, so its owner
    /// takes it again or shows none.
    public func image(for key: String) -> CGImage? {
        guard let picture = images[key] else { return nil }
        guard let image = picture.image() else {
            remove(key)
            return nil
        }
        touch(key)
        return image
    }

    /// Whether an image of `bytes` would be kept now: a caller skips work whose picture would be refused.
    public func fits(bytes: Int) -> Bool { bytes <= capacityBytes }

    /// `image` as this cache keeps it, for ``insert(_:for:)``: the image itself with feature `purgeableImageCaches`
    /// off, else a copy drawn into purgeable pages off the main actor. Nil, with no copy made, when the cache would
    /// refuse it now or the pages cannot be made.
    ///
    /// - Parameter image: The picture.
    public func picture(of image: CGImage) async -> PurgeablePicture? {
        guard fits(bytes: PurgeablePicture.byteCount(keeping: image, allocator: allocator)) else { return nil }
        return await PurgeablePicture.keeping(image, allocator: allocator)
    }

    /// Keeps `picture` (from ``picture(of:)``) for `key` as the most recent one; it copies no pixels. A picture
    /// larger than the cap now, or none (nil: refused or not made), is not kept, and the key's older one goes with
    /// it. Older pictures are dropped only as far as the cache would grow past its size before the insert: the
    /// drop down to a lowered cap is the release slices' work.
    ///
    /// - Returns: Whether `picture` was kept.
    @discardableResult
    public func insert(_ picture: PurgeablePicture?, for key: String) -> Bool {
        let ceiling = max(capacityBytes, totalBytes)
        remove(key)
        guard let picture, picture.byteCount <= capacityBytes else { return false }
        picture.attach(to: ledger)
        images[key] = picture
        order.append(key)
        totalBytes += picture.byteCount
        while totalBytes > ceiling, order.first != key, let oldest = order.first {
            remove(oldest)
        }
        return true
    }

    public func remove(_ key: String) {
        guard let picture = images.removeValue(forKey: key) else { return }
        picture.attach(to: nil)
        totalBytes -= picture.byteCount
        order.removeAll { $0 == key }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

extension PreviewImageCache: MemoryConsumer {
    /// Keeps the limit: the cap scales with it from the next insert. Frees nothing.
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        memoryLimit = limit
    }

    /// Drops the oldest images until the cache fits the slice's limit, one at a time until the slice expires.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        let capacity = slice.limit.scale(fullCapacityBytes)
        while totalBytes > capacity, let oldest = order.first {
            if slice.isExpired { return .more }
            remove(oldest)
        }
        return .done
    }

    /// The decoded bytes, locked (footprint) apart from volatile, and the image count, from counters.
    public var memoryUsage: MemoryUsage? {
        ledger.usage(totalBytes: totalBytes, entries: images.count)
    }
}
