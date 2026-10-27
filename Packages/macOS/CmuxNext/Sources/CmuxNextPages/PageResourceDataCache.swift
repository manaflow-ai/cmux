public import CmuxNextCompat
public import Foundation

/// The encoded images a page's ``PageDynamicResourceSource`` (the app's Settings backdrop thumbnails,
/// the Apps page's glyphs) already answered, by request key, as one lossless memory consumer.
///
/// Chrome keeps such decoded and encoded resources in caches its memory coordinator may empty
/// (`base/memory_coordinator/memory_consumer.h`; the image decode cache of
/// `cc/tiles/software_image_decode_cache.cc` drops its entries on critical pressure). Here an entry is
/// only an encoding of something the source can draw again, so releasing one only means the next
/// request draws it again. The keys come from the source's bounded catalog; the consumer honors no
/// partial limit: at the critical limit it keeps nothing and stores nothing new, and the
/// coordinator's release slices drop what it holds. ``memoryUsage`` reads one byte counter.
@MainActor
public final class PageResourceDataCache {
    /// Lossless, memory only, cheap to rebuild (one draw or decode); it acts at critical only.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .medium,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .cheap,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: false
    )

    private var entries: [String: Data] = [:]
    /// The bytes of the stored entries, kept on every store and removal.
    public private(set) var storedBytes = 0
    /// The limit the memory coordinator gave last; at the critical limit nothing is stored.
    public private(set) var memoryLimit: MemoryLimit = .default
    private var registration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - name: The consumer's name in the memory report (stable, kebab-case).
    ///   - memory: The app's memory coordinator; nil keeps every entry for the source's life (tests).
    public init(name: String, memory: (any MemoryConsumerRegistry)?) {
        if let memory {
            registration = MemoryConsumerRegistration(name: name, traits: Self.memoryTraits, consumer: self, registry: memory)
        }
    }

    /// How many entries it holds.
    public var count: Int { entries.count }

    /// The stored data for `key`, or nil when it was never stored or was released.
    public subscript(key: String) -> Data? { entries[key] }

    /// Keeps `data` for `key`, unless the memory limit is critical.
    public func store(_ data: Data, for key: String) {
        guard !memoryLimit.isCritical else { return }
        storedBytes += data.count - (entries.updateValue(data, forKey: key)?.count ?? 0)
    }
}

extension PageResourceDataCache: MemoryConsumer {
    /// Keeps the limit; at critical no new entry is stored from now on. Frees nothing.
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        memoryLimit = limit
    }

    /// Drops every entry at the critical limit, one at a time until the slice expires. Any other
    /// limit keeps them all: the keys are bounded by the source's catalog.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        guard slice.limit.isCritical else { return .done }
        while let entry = entries.popFirst() {
            storedBytes -= entry.value.count
            if slice.isExpired, !entries.isEmpty { return .more }
        }
        return .done
    }

    /// The stored bytes and entries, from the counter and the dictionary's count.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: storedBytes, entries: entries.count)
    }
}
