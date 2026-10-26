import CmuxNextCompat
import CmuxNextHibernation
import Testing

/// ``HiddenFrameLRU`` (p03-rendering-099), Chrome's FrameEvictionManager for page and terminal frames:
/// a locked frame is never evicted, the least recently used unlocked frame goes first past the soft
/// limit, a frame unused 5 min goes on one deadline aimed at the oldest, and a warning or critical
/// level purges every unlocked frame. Fake clock and deadline: nothing waits.
@MainActor @Suite struct HiddenFrameLRUTests {
    private let clock = FakeClock()
    private let deadline = FakeCullDeadline()
    private let evicted = EvictionLog()

    private func makeLRU(softLimit: Int) -> HiddenFrameLRU {
        HiddenFrameLRU(softLimit: softLimit, deadline: deadline) { [clock] in clock.now }
    }

    private func page(_ key: String) -> HiddenFrameID { HiddenFrameID(kind: .page, key: key) }
    private func terminal(_ key: String) -> HiddenFrameID { HiddenFrameID(kind: .terminal, key: key) }

    private func add(_ id: HiddenFrameID, locked: Bool = false, to lru: HiddenFrameLRU) {
        lru.add(id, locked: locked) { [evicted] in evicted.ids.append(id) }
    }

    @Test func theLeastRecentlyUsedUnlockedFrameGoesFirstPastTheSoftLimit() {
        let lru = makeLRU(softLimit: 2)
        add(page("a"), to: lru)
        add(terminal("b"), to: lru)
        #expect(evicted.ids.isEmpty)
        add(page("c"), to: lru)
        #expect(evicted.ids == [page("a")], "the oldest unlocked frame did not go first")
        add(terminal("d"), to: lru)
        #expect(evicted.ids == [page("a"), terminal("b")])
        #expect(lru.unlockedCount == 2)
        #expect(lru.evictedCount == 2)
    }

    @Test func aLockedFrameIsNeverEvictedByTheLimitTheCullOrPressure() {
        let lru = makeLRU(softLimit: 1)
        add(page("shown"), locked: true, to: lru)
        add(page("a"), to: lru)
        add(page("b"), to: lru)
        #expect(evicted.ids == [page("a")])
        #expect(lru.isLocked(page("shown")))

        clock.advance(.seconds(60 * 60))
        lru.cullOld()
        lru.memoryLevelDidChange(.critical)
        lru.purgeUnlocked()
        #expect(!evicted.ids.contains(page("shown")), "a locked frame was evicted")
        #expect(lru.contains(page("shown")))
    }

    @Test func locksAreCountedAndTheLastUnlockMakesTheFrameTheMostRecent() {
        let lru = makeLRU(softLimit: 2)
        add(page("a"), to: lru)
        add(page("b"), to: lru)
        lru.lock(page("a"))
        lru.lock(page("a"))
        lru.unlock(page("a"))
        #expect(lru.isLocked(page("a")), "one unlock of two locks freed the frame")
        lru.unlock(page("a"))
        #expect(!lru.isLocked(page("a")))
        // a is now more recent than b: the next frame past the limit takes b.
        add(page("c"), to: lru)
        #expect(evicted.ids == [page("b")], "the last unlock did not make the frame the most recent")
    }

    @Test func aPressureWarningPurgesEveryUnlockedFrame() {
        let lru = makeLRU(softLimit: 8)
        add(terminal("t"), locked: true, to: lru)
        for key in ["a", "b", "c"] { add(page(key), to: lru) }
        lru.memoryLevelDidChange(.normal)
        #expect(evicted.ids.isEmpty, "the normal level purged")
        lru.memoryLevelDidChange(.warning)
        #expect(Set(evicted.ids) == [page("a"), page("b"), page("c")])
        #expect(lru.unlockedCount == 0)
        #expect(lru.count == 1)
        #expect(!deadline.armed, "a cull stayed armed with no unlocked frame")
    }

    @Test func theCullTakesFramesUnusedFiveMinutesOnOneDeadlineAimedAtTheOldest() throws {
        let lru = makeLRU(softLimit: 8)
        #expect(!deadline.armed, "a cull was armed with no frame")
        add(page("old"), to: lru)
        #expect(deadline.delay == HiddenFrameLRU.periodicCullingDelay)
        clock.advance(.seconds(2 * 60))
        add(page("new"), to: lru)
        #expect(deadline.scheduled == 1, "a second frame armed a second deadline")

        clock.advance(.seconds(3 * 60))
        deadline.fire()
        #expect(evicted.ids == [page("old")])
        #expect(deadline.delay == .seconds(2 * 60), "the next look is not aimed at the oldest frame left")

        clock.advance(.seconds(2 * 60))
        deadline.fire()
        #expect(evicted.ids == [page("old"), page("new")])
        #expect(!deadline.armed, "a look armed a deadline with no unlocked frame")
    }

    @Test func aLockedFrameArmsNoCullAndTheLastUnlockedOneLeavingCancelsIt() {
        let lru = makeLRU(softLimit: 8)
        add(page("shown"), locked: true, to: lru)
        #expect(!deadline.armed)
        add(page("hidden"), to: lru)
        #expect(deadline.armed)
        lru.lock(page("hidden"))
        #expect(!deadline.armed, "the cull stayed armed once every frame was locked")
        lru.unlock(page("hidden"))
        #expect(deadline.armed)
        lru.remove(page("hidden"))
        #expect(!deadline.armed, "the cull stayed armed after the last unlocked frame left")
    }

    @Test func aHolderThatRemovesItsFrameFromTheEvictionCallbackLeavesTheListSettled() {
        let lru = makeLRU(softLimit: 1)
        let first = page("a")
        lru.add(first, locked: false) { [evicted] in
            lru.remove(first)
            evicted.ids.append(first)
        }
        add(page("b"), to: lru)
        #expect(evicted.ids == [first])
        #expect(!lru.contains(first))
        #expect(lru.unlockedCount == 1)
    }

    @Test func addingAgainReplacesTheFrameAndItsLockState() {
        let lru = makeLRU(softLimit: 4)
        add(page("a"), locked: true, to: lru)
        add(page("a"), to: lru)
        #expect(!lru.isLocked(page("a")))
        #expect(lru.count == 1)
        add(page("a"), locked: true, to: lru)
        #expect(lru.isLocked(page("a")))
        #expect(lru.unlockedCount == 0)
    }

    @Test func theSoftLimitComesFromPhysicalMemory() {
        #expect(HiddenFrameLRU.softLimit(physicalMiB: 2 * 1024) == 4)
        #expect(HiddenFrameLRU.softLimit(physicalMiB: 8 * 1024) == 10)
        #expect(HiddenFrameLRU.softLimit(physicalMiB: 16 * 1024) == 18)
        #expect(HiddenFrameLRU.softLimit(physicalMiB: 64 * 1024) == 24)
    }

    @Test func itRegistersAsOneLosslessConsumerThatReportsItsFrames() {
        let registry = FakeRegistry()
        let lru = HiddenFrameLRU(softLimit: 4, deadline: deadline, memory: registry) { [clock] in clock.now }
        add(page("a"), locked: true, to: lru)
        add(page("b"), to: lru)
        #expect(registry.names == [HiddenFrameLRU.memoryConsumerName])
        #expect(lru.memoryUsage == MemoryUsage(footprintBytes: 0, entries: 2))
        #expect(lru.releaseMemory(within: MemoryReleaseSlice(limit: .criticalThreshold) { false }) == .done)
        #expect(evicted.ids == [page("b")])
    }
}

@MainActor
private final class EvictionLog {
    var ids: [HiddenFrameID] = []
}

@MainActor
private final class FakeCullDeadline: HiddenFrameCullDeadline {
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
