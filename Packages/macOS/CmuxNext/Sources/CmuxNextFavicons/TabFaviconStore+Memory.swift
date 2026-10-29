public import CmuxNextBrowser
public import CmuxNextCompat

/// The favicon pixels have one memory consumer, "browser-favicons"
/// (`memoryBrowserCaches`): this store's strip icons and the `BrowserFaviconLoader` cache they are
/// decoded from hold the same `CGImage`s, so one release drops both and one report counts each image
/// once, as Chrome's caches follow `base/memory_coordinator/memory_consumer.h`.
///
/// The limit caps the loader's per-profile caches. This store's inserts stay at full capacity: an icon
/// lands here only because a strip shows it, and dropping it as it lands would make that strip fetch it
/// again on every read. A release drops this store's oldest icons down to the limit and bumps
/// ``revision``, so each strip still showing one fetches it once more.
extension TabFaviconStore: MemoryConsumer {
    /// Decoded icons, memory only and lossless; a dropped one is fetched again, so only critical
    /// pressure (or a Memory Saver share) shrinks it. At most 16 KiB per icon: 256 strip icons and
    /// ``BrowserFaviconLoader/entriesPerProfile`` per profile.
    static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .medium,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .expensive,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: true
    )

    /// The consumer's name in the memory report.
    static let memoryConsumerName = "browser-favicons"

    /// Registers this store and `loaderCache` as one consumer with the app's memory coordinator (once;
    /// a later call replaces the registration).
    ///
    /// - Parameters:
    ///   - registry: The memory coordinator.
    ///   - loaderCache: The loader this store fetches through (`BrowserFaviconLoader.shared`).
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry, loaderCache: BrowserFaviconLoader) {
        self.loaderCache = loaderCache
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// Passes `limit` to the loader's caches. Frees nothing.
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        loaderCache?.updateMemoryLimit(limit)
    }

    /// Drops this store's oldest icons down to `slice.limit` of its capacity, then the loader's least
    /// recently used ones, stopping when the slice expires.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        let keep = slice.limit.scale(images.capacity)
        var dropped = false
        defer { if dropped { revision += 1 } }
        while images.count > keep {
            if slice.isExpired { return .more }
            images.removeLeastRecentlyUsed()
            dropped = true
        }
        return loaderCache?.releaseMemory(within: slice) ?? .done
    }

    /// The decoded pixels of every kept icon, counted once: the loader's counters plus this store's
    /// icons the loader does not keep (at most 256 checks, read only by the memory report).
    public var memoryUsage: MemoryUsage? {
        let loaderUsage = loaderCache?.memoryUsage ?? .empty
        var bytes = loaderUsage.footprintBytes
        var entries = loaderUsage.entries
        images.forEach { key, image in
            if loaderCache?.keepsFavicon(at: key.url, profile: key.profile) == true { return }
            bytes += image.cgImage.width * image.cgImage.height * 4
            entries += 1
        }
        return MemoryUsage(footprintBytes: bytes, entries: entries)
    }
}
