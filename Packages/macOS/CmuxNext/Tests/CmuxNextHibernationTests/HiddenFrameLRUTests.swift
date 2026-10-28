import CmuxNextCompat
import CmuxNextHibernation
import Testing

/// ``HiddenFrameLRU``, Chrome's FrameEvictionManager for terminal frames: a
/// locked frame is never evicted, the least recently used unlocked frame goes first past the soft
/// limit on the evictions deadline (never in the culling turn), a frame unused 5 min goes on one
/// deadline aimed at the oldest, and a lowered memory limit (warning or critical) purges every
/// unlocked frame in the coordinator's release slices. Fake clock and deadlines: nothing waits.
@MainActor @Suite struct HiddenFrameLRUTests {
    private let clock = FakeClock()
    private let deadline = FakeDeadline()
    private let evictions = FakeDeadline()
    private let evicted = EvictionLog()

    private func makeLRU(softLimit: Int, memory: (any MemoryConsumerRegistry)? = nil) -> HiddenFrameLRU {
        HiddenFrameLRU(softLimit: softLimit, deadline: deadline, evictions: evictions, memory: memory) { [clock] in clock.now }
    }

    private func frame(_ key: String) -> HiddenFrameID { HiddenFrameID(kind: .terminal, key: key) }

    private func add(_ id: HiddenFrameID, locked: Bool = false, to lru: HiddenFrameLRU) {
        lru.add(id, locked: locked) { [evicted] in evicted.ids.append(id) }
    }

    /// A slice at `percent` that never ends.
    private func slice(_ percent: Int) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: MemoryLimit(percent: percent)) { false }
    }

    @Test func theLeastRecentlyUsedUnlockedFrameGoesFirstPastTheSoftLimit() {
        let lru = makeLRU(softLimit: 2)
        add(frame("a"), to: lru)
        add(frame("b"), to: lru)
        #expect(!evictions.armed)
        add(frame("c"), to: lru)
        add(frame("d"), to: lru)
        #expect(evicted.ids.isEmpty, "a holder dropped its frame in the turn that culled it")
        #expect(lru.pendingEvictionCount == 2)
        #expect(evictions.scheduled == 1, "a second cull armed a second evictions deadline")
        evictions.fire()
        #expect(evicted.ids == [frame("a"), frame("b")], "the oldest unlocked frames did not go first")
        #expect(lru.unlockedCount == 2)
        #expect(lru.evictedCount == 2)
        #expect(lru.pendingEvictionCount == 0)
    }

    @Test func aCulledFrameLockedBeforeItsDropStays() {
        let lru = makeLRU(softLimit: 1)
        add(frame("read"), to: lru)
        add(frame("b"), to: lru)
        lru.lock(frame("read"))
        #expect(lru.isLocked(frame("read")), "a frame read again before its drop was not kept")
        #expect(!evictions.armed, "the evictions deadline stayed armed with nothing to drop")
        evictions.fire()
        #expect(evicted.ids.isEmpty)
        lru.unlock(frame("read"))
        evictions.fire()
        #expect(evicted.ids == [frame("b")], "the unlock did not make the frame the most recent")
    }

    @Test func aCulledFrameRemovedBeforeItsDropIsNotDropped() {
        let lru = makeLRU(softLimit: 1)
        add(frame("a"), to: lru)
        add(frame("b"), to: lru)
        lru.remove(frame("a"))
        #expect(!evictions.armed)
        add(frame("a"), locked: true, to: lru)
        evictions.fire()
        #expect(evicted.ids.isEmpty, "a frame that left on its own, or its replacement, was dropped")
        #expect(lru.isLocked(frame("a")))
    }

    @Test func aLockedFrameIsNeverEvictedByTheLimitTheCullOrPressure() {
        let lru = makeLRU(softLimit: 1)
        add(frame("shown"), locked: true, to: lru)
        add(frame("a"), to: lru)
        add(frame("b"), to: lru)
        evictions.fire()
        #expect(evicted.ids == [frame("a")])
        #expect(lru.isLocked(frame("shown")))

        clock.advance(.seconds(60 * 60))
        lru.cullOld()
        #expect(lru.releaseMemory(within: slice(0)) == .done)
        #expect(!evicted.ids.contains(frame("shown")), "a locked frame was evicted")
        #expect(lru.contains(frame("shown")))
    }

    @Test func locksAreCountedAndTheLastUnlockMakesTheFrameTheMostRecent() {
        let lru = makeLRU(softLimit: 2)
        add(frame("a"), to: lru)
        add(frame("b"), to: lru)
        lru.lock(frame("a"))
        lru.lock(frame("a"))
        lru.unlock(frame("a"))
        #expect(lru.isLocked(frame("a")), "one unlock of two locks freed the frame")
        lru.unlock(frame("a"))
        #expect(!lru.isLocked(frame("a")))
        // a is now more recent than b: the next frame past the limit takes b.
        add(frame("c"), to: lru)
        evictions.fire()
        #expect(evicted.ids == [frame("b")], "the last unlock did not make the frame the most recent")
    }

    @Test func aLoweredLimitPurgesEveryUnlockedFrameInTheReleaseSlices() {
        let lru = makeLRU(softLimit: 2)
        add(frame("t"), locked: true, to: lru)
        for key in ["a", "b", "c"] { add(frame(key), to: lru) }
        #expect(lru.releaseMemory(within: slice(100)) == .done)
        #expect(evicted.ids.isEmpty, "the full limit purged")
        // A warning's limit (50 % times the Memory Saver share): the culled frame goes first, then the rest.
        #expect(lru.releaseMemory(within: slice(25)) == .done)
        #expect(evicted.ids == [frame("a"), frame("b"), frame("c")])
        #expect(lru.unlockedCount == 0)
        #expect(lru.pendingEvictionCount == 0)
        #expect(lru.count == 1)
        #expect(!deadline.armed, "a cull stayed armed with no unlocked frame")
        #expect(!evictions.armed, "the evictions deadline stayed armed with nothing to drop")
    }

    @Test func aPurgeStopsWhenItsSliceEndsAndGoesOnInTheNext() {
        let lru = makeLRU(softLimit: 8)
        for key in ["a", "b", "c"] { add(frame(key), to: lru) }
        let checks = SliceChecks(allowed: 1)
        let short = MemoryReleaseSlice(limit: MemoryLimit(percent: 50)) { checks.take() }
        #expect(lru.releaseMemory(within: short) == .more)
        #expect(evicted.ids == [frame("a")], "the purge ran past the end of its slice")
        #expect(lru.releaseMemory(within: slice(50)) == .done)
        #expect(evicted.ids == [frame("a"), frame("b"), frame("c")])
    }

    @Test func theCullTakesFramesUnusedFiveMinutesOnOneDeadlineAimedAtTheOldest() {
        let lru = makeLRU(softLimit: 8)
        #expect(!deadline.armed, "a cull was armed with no frame")
        add(frame("old"), to: lru)
        #expect(deadline.delay == HiddenFrameLRU.periodicCullingDelay)
        clock.advance(.seconds(2 * 60))
        add(frame("new"), to: lru)
        #expect(deadline.scheduled == 1, "a second frame armed a second deadline")

        clock.advance(.seconds(3 * 60))
        deadline.fire()
        #expect(evicted.ids == [frame("old")])
        #expect(deadline.delay == .seconds(2 * 60), "the next look is not aimed at the oldest frame left")

        clock.advance(.seconds(2 * 60))
        deadline.fire()
        #expect(evicted.ids == [frame("old"), frame("new")])
        #expect(!deadline.armed, "a look armed a deadline with no unlocked frame")
    }

    @Test func aLockedFrameArmsNoCullAndTheLastUnlockedOneLeavingCancelsIt() {
        let lru = makeLRU(softLimit: 8)
        add(frame("shown"), locked: true, to: lru)
        #expect(!deadline.armed)
        add(frame("hidden"), to: lru)
        #expect(deadline.armed)
        lru.lock(frame("hidden"))
        #expect(!deadline.armed, "the cull stayed armed once every frame was locked")
        lru.unlock(frame("hidden"))
        #expect(deadline.armed)
        lru.remove(frame("hidden"))
        #expect(!deadline.armed, "the cull stayed armed after the last unlocked frame left")
    }

    @Test func aHolderThatRemovesItsFrameFromTheEvictionCallbackLeavesTheListSettled() {
        let lru = makeLRU(softLimit: 1)
        let first = frame("a")
        lru.add(first, locked: false) { [evicted] in
            lru.remove(first)
            evicted.ids.append(first)
        }
        add(frame("b"), to: lru)
        evictions.fire()
        #expect(evicted.ids == [first])
        #expect(!lru.contains(first))
        #expect(lru.unlockedCount == 1)
    }

    @Test func addingAgainReplacesTheFrameAndItsLockState() {
        let lru = makeLRU(softLimit: 4)
        add(frame("a"), locked: true, to: lru)
        add(frame("a"), to: lru)
        #expect(!lru.isLocked(frame("a")))
        #expect(lru.count == 1)
        add(frame("a"), locked: true, to: lru)
        #expect(lru.isLocked(frame("a")))
        #expect(lru.unlockedCount == 0)
    }

    @Test func theSoftLimitComesFromPhysicalMemory() {
        #expect(HiddenFrameLRU.softLimit(physicalMiB: 2 * 1024) == 4)
        #expect(HiddenFrameLRU.softLimit(physicalMiB: 8 * 1024) == 10)
        #expect(HiddenFrameLRU.softLimit(physicalMiB: 16 * 1024) == 18)
        #expect(HiddenFrameLRU.softLimit(physicalMiB: 64 * 1024) == 24)
    }

    @Test func itRegistersAsOneManagedLosslessConsumerThatReportsItsFrames() {
        let registry = FakeRegistry()
        let lru = makeLRU(softLimit: 4, memory: registry)
        add(frame("a"), locked: true, to: lru)
        add(frame("b"), to: lru)
        #expect(registry.names == [HiddenFrameLRU.memoryConsumerName])
        #expect(HiddenFrameLRU.memoryTraits.isManaged, "a warning would not lower the list's limit")
        #expect(lru.memoryUsage == MemoryUsage(footprintBytes: 0, entries: 2))
        #expect(lru.releaseMemory(within: slice(0)) == .done)
        #expect(evicted.ids == [frame("b")])
    }
}

/// Lets a slice run `allowed` checks, then ends it (the slice's check is a `@Sendable` closure).
private nonisolated final class SliceChecks: Sendable {
    private let used = Atomic<Int>(0)
    private let allowed: Int

    init(allowed: Int) {
        self.allowed = allowed
    }

    /// Whether the slice is used up; each call spends one check.
    func take() -> Bool {
        used.add(1, ordering: .relaxed).oldValue >= allowed
    }
}

@MainActor
private final class EvictionLog {
    var ids: [HiddenFrameID] = []
}

@MainActor
private final class FakeDeadline: HiddenFrameDeadline {
    private(set) var delay: Duration?
    /// How many times a deadline was armed.
    private(set) var scheduled = 0
    private var action: (@MainActor () -> Void)?
    var armed: Bool { action != nil }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
        scheduled += 1
    }

    func cancel() {
        delay = nil
        action = nil
    }

    func fire() {
        guard let action else { return }
        self.action = nil
        delay = nil
        action()
    }
}

@MainActor
private final class FakeClock {
    private(set) var now = ContinuousClock.now
    func advance(_ duration: Duration) { now = now.advanced(by: duration) }
}

@MainActor
private final class FakeRegistry: MemoryConsumerRegistry {
    private(set) var names: [String] = []

    func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
        names.append(entry.name)
        entry.consumer?.updateMemoryLimit(.default)
    }
}
