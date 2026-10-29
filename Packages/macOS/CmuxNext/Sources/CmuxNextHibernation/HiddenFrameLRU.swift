package import CmuxNextCompat
package import CmuxNextWakeups

/// A one-shot deadline of ``HiddenFrameLRU``: a `background` ``MainDeadline`` in the app, a fake in tests.
@MainActor
package protocol HiddenFrameDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    /// Drops the pending deadline.
    func cancel()
}

extension MainDeadline: HiddenFrameDeadline {}

/// The app's one list of frames kept for hidden panes: evicted terminals' last frames
/// (p03-rendering.md R6), built in `AppServices` behind `memoryHiddenFrameLRU`.
///
/// A port of Chrome's `components/viz/client/frame_eviction_manager.cc`, which keeps "a minimum
/// amount, as an LRU cache, to make switching between a small set of tabs faster":
///
/// - **Locks.** A shown or read frame is locked (`LockFrame`, counted) and never evicted. Its last
///   unlock makes it the most recently used unlocked frame (`RegisterUnlockedFrame`).
/// - **Soft limit.** Past ``softLimit`` unlocked frames the least recently used goes first
///   (`CullUnlockedFrames`). The limit comes from physical memory (``softLimit(physicalMiB:)``).
/// - **Periodic cull.** An unlocked frame unused for ``periodicCullingDelay`` (Chrome's
///   `kPeriodicCullingDelay`, 5 min) goes (`CullOldUnlockedFrames`). Chrome runs a repeating timer;
///   here one deadline aims at the oldest unlocked frame, and none is armed with no unlocked frame.
/// - **Pressure.** Chrome's `OnMemoryPressure` culls to 50 % of its saved-frame limit at moderate
///   pressure and to 10 % at critical (`PurgeMemory`). cmux purges every unlocked frame once the
///   memory coordinator lowers its limit (warning or critical), as the task asks, in the
///   coordinator's release slices.
///
/// The list's bookkeeping is synchronous, but no holder's drop runs on the turn that decided it: a
/// frame culled past the limit waits for the ``init(softLimit:deadline:evictions:memory:now:)``
/// `evictions` deadline (background work), the 5 min cull runs on its own background deadline, and
/// a pressure purge runs in the release slices and stops when a slice ends. An unlock in an action's
/// turn (a workspace switch) so costs the action only the list edit. A frame locked again before
/// its drop runs stays.
///
/// It counts only unlocked frames against the limit, where Chrome counts locked ones too: a Chrome
/// window shows one tab, while a cmux window shows several panes at once, each locked, and the
/// limit is about what hidden panes keep. A holder may keep its own memory bound as well
/// (`TerminalLastFrames` keeps the warm set's capacity); the list never raises it.
///
/// Browser pages are not in it: dropping a hosted page view frees nothing while Chromium keeps the
/// page's compositor surface (see ``HiddenFrameID/Kind``).
@MainActor
package final class HiddenFrameLRU {
    /// Chrome's `kPeriodicCullingDelay`.
    package static let periodicCullingDelay: Duration = .seconds(5 * 60)

    /// How the list shows to the memory coordinator: lossless (a pane shown again draws a fresh
    /// frame), memory only, cheap to rebuild, and managed, so a warning lowers its limit and the
    /// coordinator's release slices purge it.
    package static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    /// The consumer's name in the memory report.
    package static let memoryConsumerName = "hidden-frames"

    /// Unlocked frames kept for a Mac with `physicalMiB` of memory (`SubsystemBudget.physicalMiB`):
    /// Chrome's shape (2 plus one frame per step of memory, `std::min(5, 2 +
    /// AmountOfPhysicalMemoryMB() / 256)`) with a step of 1 GB and 4...24 in place of 256 MB and 5. A
    /// kept frame here is a full pane at the display's scale (about 20 MB at full-screen Retina), and
    /// the list holds every window's terminals; 24 is the warm set's largest terminal capacity
    /// (`WarmSetBudget`), and 4 keeps the four most recent tabs on the smallest Mac.
    package static func softLimit(physicalMiB: Int) -> Int {
        min(24, max(4, 2 + physicalMiB / 1024))
    }

    /// How many unlocked frames it keeps.
    package let softLimit: Int
    /// Frames whose holder dropped them on the list's word so far (limit, cull and pressure; tests
    /// and diagnostics).
    package private(set) var evictedCount = 0

    private struct Locked {
        var count: Int
        let evict: @MainActor () -> Void
    }

    private struct Unlocked {
        let id: HiddenFrameID
        /// When its last lock ended, or it was added unlocked.
        let since: ContinuousClock.Instant
        let evict: @MainActor () -> Void
    }

    private var locked: [HiddenFrameID: Locked] = [:]
    /// Unlocked frames, least recently used first: at most ``softLimit`` (24) between turns, so the
    /// edits are O(softLimit).
    private var unlocked: [Unlocked] = []
    /// Frames culled past the limit whose holders drop them on the `evictions` deadline, oldest first.
    private var culled: [Unlocked] = []
    private let cullDeadline: any HiddenFrameDeadline
    private let evictionDeadline: any HiddenFrameDeadline
    private let now: () -> ContinuousClock.Instant
    /// Whether the periodic cull's deadline is armed.
    private var cullArmed = false
    /// Whether the culled frames' drop is armed.
    private var evictionsArmed = false
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - softLimit: Unlocked frames kept; ``softLimit(physicalMiB:)`` of the Mac in the app.
    ///   - deadline: The one deadline of the periodic cull.
    ///   - evictions: The deadline on which holders drop the frames culled past the limit.
    ///   - memory: The app's memory coordinator, whose lowered limits (warning, critical) purge the
    ///     unlocked frames in its release slices; nil never purges.
    ///   - now: The injected clock of unlock times.
    package init(softLimit: Int, deadline: any HiddenFrameDeadline, evictions: any HiddenFrameDeadline,
                 memory: (any MemoryConsumerRegistry)? = nil, now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.softLimit = max(0, softLimit)
        cullDeadline = deadline
        evictionDeadline = evictions
        self.now = now
        memoryRegistration = memory.map {
            MemoryConsumerRegistration(name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: $0)
        }
    }

    /// Frames kept now, locked or not; culled ones whose drop waits are not counted.
    package var count: Int { locked.count + unlocked.count }
    /// Unlocked frames kept now.
    package var unlockedCount: Int { unlocked.count }
    /// Culled frames whose holders have not dropped them yet.
    package var pendingEvictionCount: Int { culled.count }
    /// Whether `id` is kept and locked.
    package func isLocked(_ id: HiddenFrameID) -> Bool { locked[id] != nil }
    /// Whether `id` is kept, locked or not.
    package func contains(_ id: HiddenFrameID) -> Bool { locked[id] != nil || unlocked.contains { $0.id == id } }
    /// Whether the periodic cull's deadline is armed.
    package var isCullArmed: Bool { cullArmed }

    /// The cull deadline's look: evicts the unlocked frames unused for ``periodicCullingDelay``,
    /// oldest first, and aims the next look at the oldest one left. It runs as background work, so
    /// the holders drop their frames here.
    package func cullOld() {
        cullArmed = false
        let at = now()
        while let oldest = unlocked.first, at - oldest.since >= Self.periodicCullingDelay {
            unlocked.removeFirst()
            evict(oldest)
        }
        armCull()
    }

    /// The evictions deadline: the holders of the frames culled past the limit drop them.
    package func dropCulled() {
        evictionsArmed = false
        while !culled.isEmpty {
            evict(culled.removeFirst())
        }
    }

    private func forget(_ id: HiddenFrameID) {
        locked[id] = nil
        if let index = unlocked.firstIndex(where: { $0.id == id }) { unlocked.remove(at: index) }
        if let index = culled.firstIndex(where: { $0.id == id }) { culled.remove(at: index) }
        if culled.isEmpty { disarmEvictions() }
    }

    /// Chrome's `RegisterUnlockedFrame`: the most recently used, then the cull to the limit. The
    /// culled frames' holders drop them on the evictions deadline, not in this turn.
    private func registerUnlocked(_ id: HiddenFrameID, evict: @escaping @MainActor () -> Void) {
        unlocked.append(Unlocked(id: id, since: now(), evict: evict))
        if unlocked.count > softLimit {
            culled.append(contentsOf: unlocked.prefix(unlocked.count - softLimit))
            unlocked.removeFirst(unlocked.count - softLimit)
            armEvictions()
        }
        armCull()
    }

    private func evict(_ frame: Unlocked) {
        evictedCount += 1
        frame.evict()
    }

    /// Arms the one deadline for when the oldest unlocked frame turns ``periodicCullingDelay``. An
    /// armed deadline stays: a look with nothing due aims again.
    private func armCull() {
        guard let oldest = unlocked.first else { return disarmCull() }
        guard !cullArmed else { return }
        cullArmed = true
        let wait = Self.periodicCullingDelay - (now() - oldest.since)
        cullDeadline.schedule(after: max(.zero, wait)) { [weak self] in self?.cullOld() }
    }

    private func disarmCull() {
        guard cullArmed else { return }
        cullArmed = false
        cullDeadline.cancel()
    }

    private func armEvictions() {
        guard !evictionsArmed else { return }
        evictionsArmed = true
        evictionDeadline.schedule(after: .zero) { [weak self] in self?.dropCulled() }
    }

    private func disarmEvictions() {
        guard evictionsArmed else { return }
        evictionsArmed = false
        evictionDeadline.cancel()
    }
}

extension HiddenFrameLRU: HiddenFrameKeeper {
    package func add(_ id: HiddenFrameID, locked isLocked: Bool, evict: @escaping @MainActor () -> Void) {
        forget(id)
        if isLocked {
            locked[id] = Locked(count: 1, evict: evict)
            if unlocked.isEmpty { disarmCull() }
        } else {
            registerUnlocked(id, evict: evict)
        }
    }

    package func remove(_ id: HiddenFrameID) {
        forget(id)
        if unlocked.isEmpty { disarmCull() }
    }

    /// A culled frame whose drop has not run yet is kept again: its holder reads it now.
    package func lock(_ id: HiddenFrameID) {
        if let index = unlocked.firstIndex(where: { $0.id == id }) {
            let frame = unlocked.remove(at: index)
            locked[id] = Locked(count: 1, evict: frame.evict)
            if unlocked.isEmpty { disarmCull() }
        } else if let index = culled.firstIndex(where: { $0.id == id }) {
            let frame = culled.remove(at: index)
            locked[id] = Locked(count: 1, evict: frame.evict)
            if culled.isEmpty { disarmEvictions() }
        } else {
            locked[id]?.count += 1
        }
    }

    package func unlock(_ id: HiddenFrameID) {
        guard var frame = locked[id] else { return }
        frame.count -= 1
        guard frame.count == 0 else {
            locked[id] = frame
            return
        }
        locked[id] = nil
        registerUnlocked(id, evict: frame.evict)
    }
}

// A memory consumer of the app's coordinator, managed so that a warning lowers its limit as well as
// critical does. Below the full limit it purges every unlocked frame, one holder's drop at a time
// until the slice ends; at the full limit it keeps its soft limit.
extension HiddenFrameLRU: MemoryConsumer {
    /// Frees nothing: the release slices purge.
    package func updateMemoryLimit(_ limit: MemoryLimit) {}

    package func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        guard slice.limit < .default else { return .done }
        while !culled.isEmpty {
            if slice.isExpired { return .more }
            evict(culled.removeFirst())
        }
        disarmEvictions()
        while !unlocked.isEmpty {
            if slice.isExpired { return .more }
            evict(unlocked.removeFirst())
        }
        disarmCull()
        return .done
    }

    /// The count only: each holder reports its own bytes (`TerminalLastFrames` its volatile ones).
    package var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: 0, entries: count + culled.count)
    }
}
