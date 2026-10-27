public import CmuxNextCompat

/// Evicted terminals' last frames (`TerminalLastFrame`), oldest dropped first past ``capacity``, and
/// with a ``keeper`` (`memoryHiddenFrameLRU`) also dropped when the app-wide list evicts them.
///
/// The bound is the warm set's terminal capacity (`WarmSetBudget`: 24 at most, 6 at warning, none
/// at critical). A change of the bound frees nothing at once: it bounds the next frame kept, which
/// drops the oldest past it. Each frame is one full-resolution drawable (about 20 MB for a
/// full-screen Retina pane), volatile while it waits, so memory pressure takes its pages first. A
/// closed tab's frame is never asked for again: it ages out under the bound, volatile meanwhile.
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
/// reader makes the pages volatile again when it ends.
///
/// With a ``keeper`` (the App's `HiddenFrameLRU`, `memoryHiddenFrameLRU`) each kept frame is also one
/// unlocked frame of the app-wide list, locked while a reader holds it, and the list may drop it
/// sooner (its soft limit, its 5 min cull, a memory warning). The warm set's capacity stays the upper
/// bound: the list never keeps more than it allows (6 at warning, none at a capacity of 0). A frame
/// that leaves the store on its own leaves the list too.
///
/// Registered (`memoryTerminalLastFrames`), it is one lossless memory consumer (a dropped frame only
/// means the re-attached terminal shows its replay without a picture first) that releases only
/// memory and honors no partial limit. The critical limit is its one release: from then on no frame
/// is kept, and the coordinator's release slices drop the stored ones, oldest first, on later
/// frames. ``memoryUsage`` reports the non-volatile bytes as footprint and the rest as volatile
/// bytes, from two counters.
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
    /// The bytes of stored frames that are not volatile now (a reader holds them), kept on every
    /// insert, removal and pin change. 0 at rest.
    public private(set) var nonVolatileBytes = 0
    /// What each eviction kept and each re-attach showed (`debug.surfaces` last_frames).
    public private(set) var outcomes: [String: Int] = [:]
    /// The limit the memory coordinator gave last; at the critical limit no frame is kept.
    public private(set) var memoryLimit: MemoryLimit = .default
    private var memoryRegistration: MemoryConsumerRegistration?
    /// The app-wide list of hidden frames that may drop frames under ``capacity``; nil: only
    /// ``capacity`` bounds. Set once at launch, before any frame is kept.
    public var keeper: (any HiddenFrameKeeper)?

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

    /// The warm set's capacity changed. Frees nothing: the next frame kept drops the oldest past it.
    public func setCapacity(_ newCapacity: Int) {
        capacity = max(0, newCapacity)
    }

    /// Keeps `frame` for `key`; returns how many frames the bound dropped.
    func insert(_ frame: TerminalLastFrame, for key: String) -> Int {
        remove(key)
        frames[key] = frame
        order.append(key)
        storedBytes += frame.bytes
        if !frame.isVolatile { nonVolatileBytes += frame.bytes }
        frame.onEvent = { [weak self, weak frame] event in
            guard let self, let frame else { return }
            self.frameDidChange(frame, for: key, event: event)
        }
        keeper?.add(Self.frameID(key), locked: !frame.isVolatile) { [weak self, weak frame] in
            guard let self, let frame, self.frames[key] === frame else { return }
            self.remove(key)
            self.note("dropped")
        }
        var dropped = 0
        while order.count > keptCapacity {
            dropOldest()
            dropped += 1
        }
        return dropped
    }

    @discardableResult
    public func remove(_ key: String) -> TerminalLastFrame? {
        guard let frame = frames.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        unlink(frame, key: key)
        return frame
    }

    public func note(_ outcome: String) { outcomes[outcome, default: 0] += 1 }

    /// The warm set evicts `session` (`key`), still in its window: keeps its frame, unless the
    /// eviction is a pressure drop (`atOnce`), no frame may be kept (capacity 0 or the critical
    /// memory limit) or the terminal shows no output yet.
    public func evict(_ session: TerminalSession, key: String, atOnce: Bool) {
        evict(key, atOnce: atOnce, showsOutput: session.showsOutput) { TerminalLastFrame(of: session) }
    }

    /// ``evict(_:key:atOnce:)``'s decision apart from the session: `frame` is read only when the
    /// frame is kept.
    func evict(_ key: String, atOnce: Bool, showsOutput: @autoclosure () -> Bool, frame: () -> TerminalLastFrame?) {
        remove(key)
        guard !atOnce, keptCapacity > 0 else { return note("evicted_at_once") }
        guard showsOutput() else { return note("evicted_no_output") }
        guard let frame = frame() else { return note("evicted_no_frame") }
        note("kept")
        for _ in 0..<insert(frame, for: key) { note("dropped") }
    }

    /// `key`'s new session draws now: it shows the frame that waits for it, if any.
    public func show(_ key: String, on session: TerminalSession) {
        guard let frame = remove(key) else { return }
        note(session.showLastFrame(frame) ?? "shown")
    }

    /// `debug.surfaces` last_frames: the outcome counts and the frames stored now.
    public var report: [String: Int] { outcomes.merging(["stored": count]) { $1 } }

    /// The warm set's capacity, or none at the critical memory limit.
    private var keptCapacity: Int { memoryLimit.isCritical ? 0 : capacity }

    /// A terminal's frame in the app-wide list.
    static func frameID(_ key: String) -> HiddenFrameID { HiddenFrameID(kind: .terminal, key: key) }

    private func dropOldest() {
        guard !order.isEmpty else { return }
        let key = order.removeFirst()
        if let frame = frames.removeValue(forKey: key) { unlink(frame, key: key) }
    }

    /// Takes a frame that left the store out of the counters and the keeper's list; it tells the
    /// store nothing more.
    private func unlink(_ frame: TerminalLastFrame, key: String) {
        frame.onEvent = nil
        storedBytes -= frame.bytes
        if !frame.isVolatile { nonVolatileBytes -= frame.bytes }
        keeper?.remove(Self.frameID(key))
    }

    /// A stored frame's pages changed: the counters follow, and a purged frame leaves the store, so
    /// its slot and bytes count only live frames.
    private func frameDidChange(_ frame: TerminalLastFrame, for key: String, event: TerminalLastFrame.Event) {
        guard frames[key] === frame else { return }
        switch event {
        case .becameNonVolatile:
            nonVolatileBytes += frame.bytes
            keeper?.lock(Self.frameID(key))
        case .becameVolatile:
            nonVolatileBytes -= frame.bytes
            keeper?.unlock(Self.frameID(key))
        case .purged:
            remove(key)
            note("purged")
        }
    }
}

extension TerminalLastFrames: MemoryConsumer {
    /// Keeps the limit; at critical no new frame is stored from now on. Frees nothing.
    public func updateMemoryLimit(_ limit: MemoryLimit) {
        memoryLimit = limit
    }

    /// Drops the oldest frames past what the limit keeps (none at critical, else ``capacity``), one
    /// at a time until the slice expires. Only the critical limit reaches it with work to do: it
    /// honors no partial limit.
    public func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        let kept = slice.limit.isCritical ? 0 : capacity
        while order.count > kept {
            if slice.isExpired { return .more }
            dropOldest()
            note(slice.limit.isCritical ? "dropped_critical" : "dropped")
        }
        return .done
    }

    /// Non-volatile bytes as footprint (0 at rest) and the volatile rest apart, from two counters.
    /// A frame the kernel purged unread still counts until a reader finds it purged or it is dropped.
    public var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: nonVolatileBytes, volatileBytes: storedBytes - nonVolatileBytes, entries: count)
    }
}
