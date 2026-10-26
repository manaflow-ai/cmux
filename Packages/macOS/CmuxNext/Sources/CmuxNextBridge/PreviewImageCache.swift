public import CmuxNextCompat
public import CoreGraphics

/// Downscaled tab preview images, least recently used first out, capped by decoded byte size.
///
/// Its full size, ``fullCapacityBytes``, is the owner's share of `SubsystemBudget.imageCacheBytes`
/// (plans/cmux-next/chrome-parity/p07-memory.md, task 058): sized from the Mac's memory, never a
/// literal. Registered with the memory coordinator (``registerMemoryConsumer(name:with:)``), it is a
/// lossless memory consumer that only drops decoded pixels, as Chrome's decoded image caches drop
/// their unused decodes on memory pressure (`cc/tiles/software_image_decode_cache.cc` and
/// `gpu_image_decode_cache.cc`, `OnMemoryPressure`). A new limit only lowers ``capacityBytes``, so the
/// cache stops growing; the coordinator's release slices drop the oldest images past it, on later frames.
public final class PreviewImageCache {
    /// The consumer's traits: lossless, memory only, cheap to rebuild (a preview is pictured again on its
    /// next leave or hover), and it honors partial limits, so it is managed and gives memory back at warning.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .medium,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .cheap,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: true
    )

    /// The cap at the default limit: the owner's share of the image cache budget.
    public let fullCapacityBytes: Int
    /// The cap now: ``fullCapacityBytes`` scaled by the memory coordinator's limit.
    public var capacityBytes: Int { memoryLimit.scale(fullCapacityBytes) }
    /// The limit the memory coordinator gave last.
    public private(set) var memoryLimit: MemoryLimit = .default
    public private(set) var totalBytes = 0
    private var images: [String: CGImage] = [:]
    /// Least recently used first.
    private var order: [String] = []
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameter fullCapacityBytes: The cap at the default limit (a share of `SubsystemBudget.imageCacheBytes`).
    public init(fullCapacityBytes: Int) {
        self.fullCapacityBytes = max(0, fullCapacityBytes)
    }

    public var count: Int { images.count }

    /// Registers with the app's memory coordinator (once; a later call replaces the registration).
    ///
    /// - Parameters:
    ///   - name: The consumer's name in the memory report (`preview-images`, `page-thumbnails`).
    ///   - registry: The memory coordinator.
    public func registerMemoryConsumer(name: String, with registry: any MemoryConsumerRegistry) {
        memoryRegistration = MemoryConsumerRegistration(name: name, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    public func image(for key: String) -> CGImage? {
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    /// Keeps `image` for `key` within ``capacityBytes``, dropping the oldest past it; an image larger
    /// than the cap now is not kept.
    public func insert(_ image: CGImage, for key: String) {
        let cost = Self.cost(image)
        let capacity = capacityBytes
        guard cost <= capacity else { return }
        remove(key)
        images[key] = image
        order.append(key)
        totalBytes += cost
        while totalBytes > capacity, let oldest = order.first {
            remove(oldest)
        }
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
