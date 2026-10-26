public import CmuxNextCompat

/// Evicted terminals' last frames (`TerminalLastFrame`), oldest dropped first past ``capacity``.
///
/// The bound is the warm set's terminal capacity (`WarmSetBudget`), so frames follow the warm set's
/// pressure steps: 24 at most, 6 at warning, none at critical. Each frame is one full-resolution
/// drawable (about 20 MB for a full-screen Retina pane), volatile while it waits, so memory pressure
/// takes its pages first. A closed tab's frame is never asked for again: it ages out under the
/// bound, volatile meanwhile.
///
/// ## Why this differs from Chrome's FrameEvictionManager
///
/// Chrome's `FrameEvictionManager` (components/viz/client/frame_eviction_manager.cc) caps how many
/// saved frames stay resident and culls the least recently used unlocked ones under pressure,
/// because those frames are ordinary GPU memory that counts against the process. cmux's last frames
/// are purgeable IOSurfaces: while nothing reads them they are volatile, outside `phys_footprint`,
/// and the kernel takes their pages without asking. So the count stays at the warm set's, and the
/// only cap on what they cost is on their non-volatile bytes, at 0: a stored frame is non-volatile
/// only while a hover card renders it (a new surface takes it only after it left the store), and the
/// reader makes the pages volatile again when it ends. At critical pressure every frame goes.
///
/// It is one lossless memory consumer (a dropped frame only means the re-attached terminal shows
/// its replay without a picture first) that releases only memory. It honors no partial limit: at
/// warning the warm set already shrinks it, and only the critical limit drops everything.
/// ``memoryUsage`` reports the non-volatile bytes as footprint and the rest as volatile bytes.
@MainActor
public final class TerminalLastFrames {
    /// The consumer's traits: lossless, memory only, cheap to rebuild; it acts at critical only.
    public static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large,
        dataAccess: .none,
        retention: .lossless,
        recreateCost: .cheap,
        releaseCPUCost: .low,
        isStateful: true,
        supportsMemoryLimit: false
    )

    /// The consumer's name in the memory report.
    public static let memoryConsumerName = "terminal-last-frames"

    /// How many frames it keeps: the warm set's terminal capacity.
    public private(set) var capacity: Int

    private var frames: [String: TerminalLastFrame] = [:]
    /// Keys in eviction order, oldest first (at most `capacity`, 24: O(capacity) edits).
    private var order: [String] = []
    /// The bytes of the stored frames, kept on every insert and removal.
    public private(set) var storedBytes = 0
    /// What each eviction kept and each re-attach showed (`debug.surfaces` last_frames).
    public private(set) var outcomes: [String: Int] = [:]
    /// The limit the memory coordinator gave last; at the critical limit no frame is kept.
    public private(set) var memoryLimit: MemoryLimit = .default
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameter capacity: How many frames it keeps (the warm set's terminal capacity).
    public init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    public var count: Int { frames.count }

    public subscript(key: String) -> TerminalLastFrame? { frames[key] }

    /// Registers with the app's memory coordinator (once; a later call replaces the registration).
    ///
    /// - Parameter registry: The memory coordinator.
    public func registerMemoryConsumer(with registry: any MemoryConsumerRegistry) {
        memoryRegistration = MemoryConsumerRegistration(
            name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: registry)
    }

    /// The warm set's capacity changed: frames past it go now, oldest first.
    public func setCapacity(_ newCapacity: Int) {
        capacity = max(0, newCapacity)
        for _ in trim(to: keptCapacity) { note("dropped") }
    }

    /// Keeps `frame` for `key`; returns the frames the bound dropped.
    func insert(_ frame: TerminalLastFrame, for key: String) -> [(key: String, frame: TerminalLastFrame)] {
        remove(key)
        frames[key] = frame
        order.append(key)
        storedBytes += frame.bytes
        return trim(to: keptCapacity)
    }

    @discardableResult
    public func remove(_ key: String) -> TerminalLastFrame? {
        guard let frame = frames.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        storedBytes -= frame.bytes
        return frame
    }

    /// Drops the oldest frames past `capacity`; returns them.
    func trim(to capacity: Int) -> [(key: String, frame: TerminalLastFrame)] {
        let excess = order.count - max(0, capacity)
        guard excess > 0 else { return [] }
        let dropped = order.prefix(excess).compactMap { key in frames.removeValue(forKey: key).map { (key: key, frame: $0) } }
        order.removeFirst(excess)
        storedBytes -= dropped.reduce(0) { $0 + $1.frame.bytes }
        return dropped
    }

    public func note(_ outcome: String) { outcomes[outcome, default: 0] += 1 }

    /// The warm set evicts `session` (`key`), still in its window: keeps its frame, unless the
    /// eviction is a pressure drop (`atOnce`), the memory limit is critical or the terminal shows
    /// no output yet.
    public func evict(_ session: TerminalSession, key: String, atOnce: Bool) {
        remove(key)
        guard !atOnce, keptCapacity > 0 else { return note("evicted_at_once") }
        guard session.showsOutput else { return note("evicted_no_output") }
        guard let frame = TerminalLastFrame(of: session) else { return note("evicted_no_frame") }
        keep(frame, for: key)
    }

    /// Stores `frame` for `key` and counts what the bound dropped.
    func keep(_ frame: TerminalLastFrame, for key: String) {
        note("kept")
        for _ in insert(frame, for: key) { note("dropped") }
    }

    /// `key`'s new session draws now: it shows the frame that waits for it, if any.
    public func show(_ key: String, on session: TerminalSession) {
        guard let frame = remove(key) else { return }
        note(session.showLastFrame(frame) ?? "shown")
    }

    /// Bytes of stored frames that are not volatile now (a reader holds them). 0 at rest.
    /// O(count), at most the warm set's 24.
    public var nonVolatileBytes: Int {
        frames.values.reduce(0) { $1.isVolatile ? $0 : $0 + $1.bytes }
    }

    /// `debug.surfaces` last_frames: the outcome counts and the frames stored now.
    public var report: [String: Int] { outcomes.merging(["stored": count]) { $1 } }

    /// The warm set's capacity, or none at the critical memory limit.
    private var keptCapacity: Int { memoryLimit.isCritical ? 0 : capacity }
}

extension TerminalLastFrames: MemoryConsumer {
    /// Keeps the limit; at critical no new frame is stored from now on. Frees nothing.
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        memoryLimit = limit
    }

    /// At the critical limit drops every frame, oldest first, one at a time until the slice
    /// expires. It honors no partial limit, so no other limit reaches it with work to do: a stored
    /// frame is volatile except while a reader holds it, and the reader makes it volatile again.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        guard slice.limit.isCritical else { return .done }
        while let oldest = order.first {
            if slice.isExpired { return .more }
            remove(oldest)
            note("dropped_critical")
        }
        return .done
    }

    /// Non-volatile bytes as footprint (0 at rest) and the volatile rest apart. Volatile bytes count
    /// a frame until it is dropped, even if the system already purged its pages.
    public var memoryUsage: MemoryUsage? {
        let nonVolatile = nonVolatileBytes
        return MemoryUsage(footprintBytes: nonVolatile, volatileBytes: storedBytes - nonVolatile, entries: count)
    }
}
