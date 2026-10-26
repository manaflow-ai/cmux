package import CmuxNextCompat
package import CmuxNextWakeups

/// The one-shot deadline of ``HiddenFrameLRU``'s next periodic cull: a `background` ``MainDeadline``
/// in the app, a fake in tests.
@MainActor
package protocol HiddenFrameCullDeadline: AnyObject {
    /// Runs `action` once after `delay`, replacing a pending deadline.
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void)
    /// Drops the pending deadline.
    func cancel()
}

extension MainDeadline: HiddenFrameCullDeadline {}

/// The app's one list of frames kept for hidden panes: page panes' hosted frames and evicted
/// terminals' last frames (p03-rendering.md R6, task p03-rendering-099), built in `AppServices`
/// behind `memoryHiddenFrameLRU`.
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
/// - **Pressure.** A warning or critical memory level evicts every unlocked frame (Chrome's
///   `PurgeAllUnlockedFrames`).
///
/// It counts only unlocked frames against the limit, where Chrome counts locked ones too: a Chrome
/// window shows one tab, while a cmux window shows several panes at once, each locked, and the
/// limit is about what hidden panes keep. Holders never cap their own frames.
@MainActor
package final class HiddenFrameLRU {
    /// Chrome's `kPeriodicCullingDelay`.
    package static let periodicCullingDelay: Duration = .seconds(5 * 60)

    /// How the list shows to the memory coordinator: lossless (a pane shown again draws a fresh
    /// frame), memory only, cheap to rebuild.
    package static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .large, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: false)

    /// The consumer's name in the memory report.
    package static let memoryConsumerName = "hidden-frames"

    /// Unlocked frames kept for a Mac with `physicalMiB` of memory (`SubsystemBudget.physicalMiB`):
    /// Chrome's shape (2 plus one frame per step of memory, `std::min(5, 2 +
    /// AmountOfPhysicalMemoryMB() / 256)`) with a step of 1 GB and 4...24 in place of 256 MB and 5. A kept frame here is a full pane at the
    /// display's scale (about 20 MB at full-screen Retina), and the list holds every window's
    /// terminals and pages; 24 is the warm set's largest terminal capacity (`WarmSetBudget`), and 4
    /// keeps the four most recent tabs on the smallest Mac.
    package static func softLimit(physicalMiB: Int) -> Int {
        min(24, max(4, 2 + physicalMiB / 1024))
    }

    /// How many unlocked frames it keeps.
    package let softLimit: Int
    /// Frames it evicted so far (limit, cull and pressure; tests and diagnostics).
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
    private let deadline: any HiddenFrameCullDeadline
    private let now: () -> ContinuousClock.Instant
    /// Whether the cull deadline is armed.
    private var cullArmed = false
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - softLimit: Unlocked frames kept; ``softLimit(physicalMiB:)`` of the Mac in the app.
    ///   - deadline: The one deadline of the periodic cull.
    ///   - memory: The app's memory coordinator, whose warning and critical levels purge the
    ///     unlocked frames; nil never purges.
    ///   - now: The injected clock of unlock times.
    package init(softLimit: Int, deadline: any HiddenFrameCullDeadline, memory: (any MemoryConsumerRegistry)? = nil,
                 now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.softLimit = max(0, softLimit)
        self.deadline = deadline
        self.now = now
        memoryRegistration = memory.map {
            MemoryConsumerRegistration(name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: $0)
        }
    }

    /// Frames kept now, locked or not.
    package var count: Int { locked.count + unlocked.count }
    /// Unlocked frames kept now.
    package var unlockedCount: Int { unlocked.count }
    /// Whether `id` is kept and locked.
    package func isLocked(_ id: HiddenFrameID) -> Bool { locked[id] != nil }
    /// Whether `id` is kept, locked or not.
    package func contains(_ id: HiddenFrameID) -> Bool { locked[id] != nil || unlocked.contains { $0.id == id } }
    /// Whether the periodic cull's deadline is armed.
    package var isCullArmed: Bool { cullArmed }

    /// Evicts every unlocked frame (Chrome's `PurgeAllUnlockedFrames`); locked ones stay.
    package func purgeUnlocked() {
        cull(to: 0)
    }

    /// The deadline's look: evicts the unlocked frames unused for ``periodicCullingDelay``, oldest
    /// first, and aims the next look at the oldest one left.
    package func cullOld() {
        cullArmed = false
        let at = now()
        while let oldest = unlocked.first, at - oldest.since >= Self.periodicCullingDelay {
            unlocked.removeFirst()
            evict(oldest)
        }
        armCull()
    }

    private func forget(_ id: HiddenFrameID) {
        locked[id] = nil
        if let index = unlocked.firstIndex(where: { $0.id == id }) { unlocked.remove(at: index) }
    }

    /// Chrome's `RegisterUnlockedFrame`: the most recently used, then the cull to the limit.
    private func registerUnlocked(_ id: HiddenFrameID, evict: @escaping @MainActor () -> Void) {
        unlocked.append(Unlocked(id: id, since: now(), evict: evict))
        cull(to: softLimit)
        armCull()
    }

    /// Evicts the least recently used unlocked frames past `limit`. Each leaves the list before its
    /// holder hears, so a holder that removes or adds frames from its callback sees the list settled.
    private func cull(to limit: Int) {
        while unlocked.count > max(0, limit) {
            evict(unlocked.removeFirst())
        }
        if unlocked.isEmpty { disarmCull() }
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
        deadline.schedule(after: max(.zero, wait)) { [weak self] in self?.cullOld() }
    }

    private func disarmCull() {
        guard cullArmed else { return }
        cullArmed = false
        deadline.cancel()
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

    package func lock(_ id: HiddenFrameID) {
        if let index = unlocked.firstIndex(where: { $0.id == id }) {
            let frame = unlocked.remove(at: index)
            locked[id] = Locked(count: 1, evict: frame.evict)
            if unlocked.isEmpty { disarmCull() }
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

// A level consumer of the app's memory coordinator: a warning or critical level purges every unlocked
// frame at once (at most ``softLimit``, each an O(1) drop), as Chrome's eviction manager does on memory
// pressure; the release slices find nothing more to do.
extension HiddenFrameLRU: MemoryLevelConsumer {
    package func memoryLevelDidChange(_ level: MemoryPressureLevel) {
        guard level != .normal else { return }
        purgeUnlocked()
    }

    package func updateMemoryLimit(_ limit: MemoryLimit) {}

    package func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        if slice.limit.isCritical { purgeUnlocked() }
        return .done
    }

    /// The count only: each holder reports its own bytes (`TerminalLastFrames` its volatile ones).
    package var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: 0, entries: count)
    }
}
