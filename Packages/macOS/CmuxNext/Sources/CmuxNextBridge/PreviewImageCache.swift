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
    private var images: [String: CGImage] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - fullCapacityBytes: The cap at the default limit (a share of `SubsystemBudget.imageCacheBytes`).
    ///   - contents: Whether its pictures can be taken again.
    public init(fullCapacityBytes: Int, contents: Contents = .rebuildable) {
        self.fullCapacityBytes = max(0, fullCapacityBytes)
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

    public func image(for key: String) -> CGImage? {
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    /// Whether an image of `bytes` would be kept now: a caller skips work whose picture would be refused.
    public func fits(bytes: Int) -> Bool { bytes <= capacityBytes }

    /// Keeps `image` for `key` as the most recent one. An image larger than the cap now is not kept, and
    /// the key's older image goes with it. Older images are dropped only as far as the cache would grow
    /// past its size before the insert: the drop down to a lowered cap is the release slices' work.
    ///
    /// - Returns: Whether `image` was kept.
    @discardableResult
    public func insert(_ image: CGImage, for key: String) -> Bool {
        let cost = Self.cost(image)
        let ceiling = max(capacityBytes, totalBytes)
        remove(key)
        guard cost <= capacityBytes else { return false }
        images[key] = image
        order.append(key)
        totalBytes += cost
        while totalBytes > ceiling, order.first != key, let oldest = order.first {
            remove(oldest)
        }
        return true
    }

    public func remove(_ key: String) {
        guard let image = images.removeValue(forKey: key) else { return }
        totalBytes -= Self.cost(image)
        order.removeAll { $0 == key }
    }

    static func cost(_ image: CGImage) -> Int {
        max(image.bytesPerRow * image.height, image.width * image.height * 4)
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

    /// The decoded bytes and image count, from counters.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: totalBytes, entries: images.count)
    }
}
