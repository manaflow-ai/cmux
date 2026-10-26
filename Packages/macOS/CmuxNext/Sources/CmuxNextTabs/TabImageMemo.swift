import CmuxNextCompat
import CoreGraphics

/// Values the tab strip draws once and reuses (tinted symbols, icon pack images, agent marks, emoji), kept
/// by key, least recently used out first, as Chrome's image decode caches do
/// (cc/tiles/software_image_decode_cache.cc on base/containers/lru_cache.h).
///
/// A lossless memory consumer (Chrome's base/memory_coordinator/memory_consumer.h): every value is drawn
/// again from its key when asked. The limit scales how many values stay; a new limit frees nothing, a release
/// frees idle values down to it, oldest first. A value used in the last ``inUse`` is the strip's working set
/// and stays, as the memory design keeps every lossless consumer's working set. Layers that show a value keep
/// their own reference, so forgetting one never changes what is on screen.
///
/// ```swift
/// let images = TabImageMemo<CGImage>(name: "tab-symbol-images", capacity: 256, bytes: TabImageMemo<CGImage>.pixelBytes(_:))
/// let image = images.value(for: key) { draw() }
/// images.registerMemoryConsumer(with: registry)
/// ```
final class TabImageMemo<Value> {
    /// How long a used value counts as in use: a release keeps it that long.
    static var inUse: Duration { .seconds(2) }

    private struct Entry {
        let value: Value
        let bytes: Int
        /// The use order of the last hit or insert (higher is more recent): the LRU order.
        var lastUse: UInt64
        /// When it was last used, on the memo's clock.
        var usedAt: Duration
    }

    /// The consumer's name in the memory report.
    let name: String
    /// Values kept at the full memory limit.
    let capacity: Int
    /// The values the memory limit lets stay now: ``capacity`` until it lowers them.
    private(set) var countLimit: Int
    /// The memory the values hold, kept on every insert and removal.
    private(set) var bytes = 0
    private let size: (Value) -> Int
    private var entries: [String: Entry] = [:]
    private var nextUse: UInt64 = 1
    /// The time since the memo was made, on its clock.
    private let elapsed: () -> Duration
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - name: The consumer's name in the memory report (stable, kebab-case).
    ///   - capacity: How many values stay at the full memory limit.
    ///   - bytes: The memory one value holds.
    ///   - clock: Times how long a used value stays in use (``inUse``); tests pass their own.
    init(name: String, capacity: Int, bytes: @escaping (Value) -> Int, clock: any Clock<Duration> = ContinuousClock()) {
        self.name = name
        self.capacity = max(capacity, 0)
        countLimit = self.capacity
        size = bytes
        elapsed = Self.elapsed(on: clock)
    }

    /// The registration marks itself released when it goes; nothing here needs the main actor.
    nonisolated deinit {}

    private static func elapsed<C: Clock<Duration>>(on clock: C) -> () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// How many values it holds.
    var count: Int { entries.count }

    /// The value for `key`, now the most recently used, or the one `make` draws, kept. Nil when `make`
    /// draws none; nothing is kept then, so the next ask draws again.
    func value(for key: String, make: () -> Value?) -> Value? {
        let now = elapsed()
        if var entry = entries[key] {
            entry.lastUse = takeUse()
            entry.usedAt = now
            entries[key] = entry
            return entry.value
        }
        guard let value = make() else { return nil }
        let entry = Entry(value: value, bytes: size(value), lastUse: takeUse(), usedAt: now)
        entries[key] = entry
        bytes += entry.bytes
        trimAfterInsert(now: now)
        return value
    }

    private func takeUse() -> UInt64 {
        defer { nextUse += 1 }
        return nextUse
    }

    /// Over the limit, idle values go oldest first; over ``capacity``, the oldest goes even when in use, so
    /// the memo never holds more than ``capacity``.
    private func trimAfterInsert(now: Duration) {
        while entries.count > countLimit, let idle = oldest(idleBefore: now - Self.inUse) { remove(idle) }
        while entries.count > capacity, let any = oldest(idleBefore: nil) { remove(any) }
    }

    /// The least recently used key, among those last used before `idleBefore` when it is given.
    private func oldest(idleBefore: Duration?) -> String? {
        var found: (key: String, use: UInt64)?
        for (key, entry) in entries where idleBefore.map({ entry.usedAt < $0 }) ?? true {
            if entry.lastUse < found?.use ?? .max { found = (key, entry.lastUse) }
        }
        return found?.key
    }

    private func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        bytes -= entry.bytes
    }

    /// Registers the memo with the app's memory coordinator under ``name``; the memo keeps the registration,
    /// and a later call replaces it.
    ///
    /// - Parameter registry: The memory coordinator (injected).
    func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration?.cancel()
        memoryRegistration = MemoryConsumerRegistration(name: name, traits: Self.memoryTraits, consumer: self, registry: registry)
    }
}

extension TabImageMemo where Value == CGImage {
    /// The pixel bytes of a drawn image.
    nonisolated static func pixelBytes(_ image: CGImage) -> Int { image.bytesPerRow * image.height }
}

extension TabImageMemo: MemoryConsumer {
    /// Small images, only memory, drawn again in a fraction of a millisecond: warning pressure shrinks them.
    static var memoryTraits: MemoryConsumerTraits {
        MemoryConsumerTraits(
            estimatedUsage: .small, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
            releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)
    }

    func updateMemoryLimit(_ limit: MemoryLimit) {
        countLimit = limit.scale(capacity)
    }

    /// Forgets idle values, least recently used first, until the slice's limit holds or its time is up.
    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        guard entries.count > countLimit else { return .done }
        let idleBefore = elapsed() - Self.inUse
        let idle = entries.filter { $0.value.usedAt < idleBefore }.sorted { $0.value.lastUse < $1.value.lastUse }
        for (key, _) in idle where entries.count > countLimit {
            if slice.isExpired { return .more }
            remove(key)
        }
        return .done
    }

    var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: bytes, entries: entries.count)
    }
}
