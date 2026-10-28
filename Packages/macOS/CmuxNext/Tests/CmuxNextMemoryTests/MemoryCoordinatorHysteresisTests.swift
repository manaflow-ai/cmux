import CmuxNextCompat
import CmuxNextMemory
import CmuxNextWakeups
import Testing

/// The working set and hysteresis of ``MemoryCoordinator``. A limit applies only to
/// entries not used in the last 2 s (``MemoryLimit/scale(_:inUse:)``), and after a fall in level the
/// lossless limits rise only once the level has not changed for 30 s, on one ``MainDeadline`` one-shot,
/// so warning/normal flaps (DC17) make one release pass and no refill between them; only limits a
/// release already ran at are held. Working-set entries a release kept are released once they age out,
/// on a second one-shot.
/// Slices run on a ``ManualSlicer`` and the deadlines on a ``MemoryDeadlineRig``, both fired by the test;
/// a consumer's entries age on the ``ManualClock``, which the test moves with the rig.
@MainActor @Suite struct MemoryCoordinatorHysteresisTests {
    let clock = ManualClock()
    let rig = MemoryDeadlineRig()
    let source = ManualMemoryPressureSource()
    let pressure: MemoryPressureEvents
    let slicer: ManualSlicer
    let coordinator: MemoryCoordinator

    init() {
        pressure = MemoryPressureEvents(source: source)
        slicer = ManualSlicer(clock: clock)
        coordinator = MemoryCoordinator(
            pressure: pressure, mode: .medium, slicer: slicer, clock: clock,
            limitRiseDeadline: MainDeadline(owner: "test.memory.limit-rise", workClass: .background, scheduler: rig.deadlines),
            workingSetDeadline: MainDeadline(owner: "test.memory.working-set", workClass: .background, scheduler: rig.deadlines))
    }

    func register(_ consumer: WorkingSetConsumer, _ traits: MemoryConsumerTraits) -> MemoryConsumerRegistration {
        MemoryConsumerRegistration(name: consumer.name, traits: traits, consumer: consumer, registry: coordinator)
    }

    @Test func twentyFlapsInSixtySecondsMakeOneReleasePassPerConsumer() {
        let cache = WorkingSetConsumer(name: "cache", entries: 8, clock: clock)
        let registration = register(cache, managedTraits())
        clock.advance(by: .seconds(10))  // every entry out of the working set
        for _ in 0..<20 {
            coordinator.pressureOverride = .warning
            slicer.drain()
            rig.advance(by: .milliseconds(1_500))
            rig.fireAtNow()
            coordinator.pressureOverride = .normal
            slicer.drain()
            rig.advance(by: .milliseconds(1_500))
            rig.fireAtNow()
        }
        #expect(cache.releasePasses == 1, "\(cache.releasePasses) release passes for 20 flaps")
        #expect(cache.keys.count == 2, "medium mode at warning keeps 25 % of 8")
        #expect(cache.limits == [100, 25], "the limit rose and fell between flaps: \(cache.limits)")
        #expect(coordinator.level == .normal)
        #expect(coordinator.limitLevel == .warning, "the warning limits rose before 30 s at normal")

        // The last fall was 1.5 s ago: 28 s more is still inside the hold.
        rig.advance(by: .seconds(28))
        rig.fireAtNow()
        #expect(cache.limits == [100, 25], "the limits rose before 30 s at normal")
        #expect(rig.hasArmedWake)

        rig.fireAndRun()
        #expect(cache.limits == [100, 25, 100])
        #expect(coordinator.limitLevel == .normal)
        #expect(!slicer.hasPendingSlice, "a rise asked for a release")
        #expect(cache.releasePasses == 1)
        #expect(!rig.hasArmedWake, "a wake is still armed after the one-shot ran: not a one-shot")
        withExtendedLifetime(registration) {}
    }

    @Test func criticalThenNormalBeforeTheFrameMakesNoReleaseCall() {
        let cache = WorkingSetConsumer(name: "cache", entries: 4, clock: clock)
        let discards = WorkingSetConsumer(name: "discards", entries: 4, clock: clock)
        let registrations = [
            register(cache, managedTraits()),
            register(discards, managedTraits(retention: .lossy, recreateCost: .expensive)),
        ]
        clock.advance(by: .seconds(10))
        source.send(.critical)
        source.send(.normal)
        slicer.drain()
        #expect(cache.releasePasses == 0, "a level that came back before its release still released")
        #expect(discards.releasePasses == 0)
        #expect(cache.keys.count == 4)
        #expect(coordinator.limitLevel == .normal, "a level whose release never ran was held")
        #expect(cache.limits == [100, 0, 100])
        #expect(!rig.hasArmedWake, "a hold was armed with nothing released to hold")
        withExtendedLifetime(registrations) {}
    }

    @Test func aRiseBackToTheHeldLevelCancelsTheHold() {
        let cache = WorkingSetConsumer(name: "cache", entries: 4, clock: clock)
        let registration = register(cache, managedTraits())
        clock.advance(by: .seconds(10))
        source.send(.critical)
        slicer.drain()
        source.send(.normal)
        #expect(rig.hasArmedWake)
        source.send(.critical)
        rig.fireAndRun()
        #expect(coordinator.limitLevel == .critical, "the cancelled hold still raised the limits")
        #expect(cache.limits == [100, 0])
        #expect(!slicer.hasPendingSlice, "a level its consumers are already at asked for a release")
        withExtendedLifetime(registration) {}
    }

    @Test func eachChangeDuringTheHoldRestartsIt() {
        let cache = WorkingSetConsumer(name: "cache", entries: 4, clock: clock)
        let registration = register(cache, managedTraits())
        clock.advance(by: .seconds(10))
        source.send(.critical)
        slicer.drain()
        source.send(.warning)
        rig.advance(by: .seconds(20))
        source.send(.normal)
        rig.advance(by: .seconds(20))
        rig.fireAtNow()
        #expect(cache.limits == [100, 0], "the hold ended 30 s after its first fall, not its last change")
        rig.fireAndRun()
        #expect(cache.limits == [100, 0, 100], "the hold did not end at the level it fell to last")
        withExtendedLifetime(registration) {}
    }

    @Test func lossyConsumersFollowTheLevelThroughTheHold() {
        let cache = WorkingSetConsumer(name: "cache", entries: 4, clock: clock)
        let discards = WorkingSetConsumer(name: "discards", entries: 4, clock: clock)
        let registrations = [
            register(cache, managedTraits()),
            register(discards, managedTraits(retention: .lossy, recreateCost: .expensive)),
        ]
        clock.advance(by: .seconds(10))
        // Warning releases the cache to 25 %; lossy consumers keep 100 % at warning.
        source.send(.warning)
        slicer.drain()
        #expect(cache.releasePasses == 1)
        // Critical then normal before the frame: the hold keeps the warning limit the cache was released
        // to, not the critical one it never was, and the lossy limit follows the level.
        source.send(.critical)
        source.send(.normal)
        #expect(coordinator.limitLevel == .warning, "the hold kept a level whose release never ran")
        #expect(cache.limits == [100, 25, 0, 25], "the lossless limit did not stop at the released level")
        #expect(discards.limits == [100, 0, 100], "the lossy limit waited for the hold")
        slicer.drain()
        #expect(discards.releasePasses == 0, "a lossy release ran after the pressure ended")
        #expect(cache.releasePasses == 1, "a lossless release ran at a level that came back before it")
        #expect(rig.hasArmedWake, "the warning limit is held with no hold armed")
        withExtendedLifetime(registrations) {}
    }

    @Test func aConsumerThatRegistersDuringTheHoldGetsTheHeldLimit() {
        let early = WorkingSetConsumer(name: "early", entries: 4, clock: clock)
        let registration = register(early, managedTraits())
        clock.advance(by: .seconds(10))
        source.send(.warning)
        slicer.drain()
        source.send(.normal)
        let late = WorkingSetConsumer(name: "late", entries: 4, clock: clock)
        let lateRegistration = register(late, managedTraits())
        #expect(late.limits == [25])
        withExtendedLifetime((registration, lateRegistration)) {}
    }

    @Test func anEntryUsedInTheLastTwoSecondsIsNeverReleasedAtWarning() {
        let cache = WorkingSetConsumer(name: "cache", entries: 8, clock: clock)
        let registration = register(cache, managedTraits())
        clock.advance(by: .seconds(10))
        cache.use("e6")
        cache.use("e7")
        cache.use("e0")
        clock.advance(by: .milliseconds(1_900))
        // Medium mode at warning: 25 %. The 3 in use, plus 25 % of the other 5 (1).
        source.send(.warning)
        slicer.drain()
        #expect(cache.keys == ["e5", "e6", "e7", "e0"])

        // Critical keeps the working set alone.
        source.send(.critical)
        slicer.drain()
        #expect(cache.keys == ["e6", "e7", "e0"])
        #expect(cache.releasedInUse == 0, "a release dropped an entry used in the last 2 s")
        withExtendedLifetime(registration) {}
    }

    @Test func workingSetEntriesKeptAtCriticalAreReleasedOnceTheyAgeOut() {
        let cache = WorkingSetConsumer(name: "cache", entries: 8, clock: clock)
        let registration = register(cache, managedTraits())
        clock.advance(by: .seconds(10))
        cache.use("e3")
        cache.use("e4")
        clock.advance(by: .milliseconds(1_900))
        source.send(.critical)
        slicer.drain()
        #expect(cache.keys == ["e3", "e4"], "critical kept more than the working set")
        #expect(rig.hasArmedWake, "nothing will release the kept working set once it ages out")
        #expect(!slicer.hasPendingSlice)

        // Nothing changes the level or the limit; the entries age out and the one-shot releases them.
        clock.advance(by: .seconds(2))
        rig.fireAndRun()
        #expect(slicer.hasPendingSlice, "the one-shot asked for no release")
        slicer.drain()
        #expect(cache.keys.isEmpty, "entries out of the working set outlived the critical limit")
        #expect(cache.releasePasses == 2)
        #expect(cache.releasedInUse == 0)
        #expect(!rig.hasArmedWake, "a release that kept nothing armed another wake")
        withExtendedLifetime(registration) {}
    }

    @Test func aConsumerStillUsingItsEntriesIsAskedAgainOnlyWhenTheFirstAgesOut() {
        let cache = WorkingSetConsumer(name: "cache", entries: 4, clock: clock)
        let registration = register(cache, managedTraits())
        clock.advance(by: .seconds(10))
        cache.use("e1")
        clock.advance(by: .seconds(1))
        cache.use("e2")
        source.send(.critical)
        slicer.drain()
        #expect(cache.keys == ["e1", "e2"])

        // e1 ages out 1 s later and e2 1 s after it: one more release as each leaves the working set.
        clock.advance(by: .seconds(1))
        rig.fireAndRun()
        slicer.drain()
        #expect(cache.keys == ["e2"], "the entry that aged out stayed")
        #expect(rig.hasArmedWake, "the entry still in use will never be released")
        clock.advance(by: .seconds(1))
        rig.fireAndRun()
        slicer.drain()
        #expect(cache.keys.isEmpty)
        #expect(cache.releasePasses == 3)
        #expect(!rig.hasArmedWake)
        withExtendedLifetime(registration) {}
    }

    @Test func aRiseToTheFullLimitMakesNoWorkingSetRelease() {
        let cache = WorkingSetConsumer(name: "cache", entries: 4, clock: clock)
        let registration = register(cache, managedTraits())
        source.send(.critical)
        slicer.drain()
        #expect(cache.keys.count == 4, "every entry is in the working set")
        source.send(.normal)
        rig.advance(by: .seconds(33))
        clock.advance(by: .seconds(33))
        rig.fireAtNow()  // the working set aged out at 2 s, the hold by 31 s
        rig.fireAtNow()
        slicer.drain()
        #expect(coordinator.limitLevel == .normal)
        #expect(cache.releasePasses == 1, "the full limit still released the aged working set")
        #expect(cache.keys.count == 4)
        withExtendedLifetime(registration) {}
    }

    @Test func keptInUseIdleTimesEndTheReleaseWithTheTimeToAgeOut() {
        #expect(MemoryReleaseProgress.finished(keptInUseIdleFor: nil) == .done)
        #expect(MemoryReleaseProgress.finished(keptInUseIdleFor: .seconds(2)) == .done)
        #expect(
            MemoryReleaseProgress.finished(keptInUseIdleFor: .milliseconds(1_500))
                == .keptWorkingSet(agesOutIn: .milliseconds(500)))
        #expect(MemoryReleaseProgress.finished(keptInUseIdleFor: .zero) == .keptWorkingSet(agesOutIn: .seconds(2)))
    }

    @Test func theWorkingSetLastsTwoSecondsAndLimitsApplyToTheRest() {
        #expect(MemoryLimit.isInWorkingSet(idle: .zero))
        #expect(MemoryLimit.isInWorkingSet(idle: .milliseconds(1_999)))
        #expect(!MemoryLimit.isInWorkingSet(idle: .seconds(2)))
        #expect(MemoryLimit(percent: 50).scale(10, inUse: 4) == 7)
        #expect(MemoryLimit.criticalThreshold.scale(10, inUse: 4) == 4)
        #expect(MemoryLimit.default.scale(10, inUse: 4) == 10)
        #expect(MemoryLimit(percent: 50).scale(3, inUse: 5) == 5, "more in use than the capacity: all kept")
        #expect(MemoryLimit(percent: 50).scale(10, inUse: -1) == 5)
    }
}

/// A lossless cache of named entries with use times, least recently used first: it reports its
/// in-use entries to ``MemoryLimit/scale(_:inUse:)`` and releases its oldest entries down to that.
@MainActor
final class WorkingSetConsumer: MemoryConsumer {
    let name: String
    private let capacity: Int
    private let clock: ManualClock
    /// The entries, least recently used first, with their last use.
    private var entries: [(key: String, used: ManualClock.Instant)]
    /// Every limit it was given, in percent.
    private(set) var limits: [Int] = []
    /// How many release calls it got.
    private(set) var releasePasses = 0
    /// Entries in the working set a release dropped (always 0 for a correct consumer).
    private(set) var releasedInUse = 0

    init(name: String, entries count: Int, clock: ManualClock) {
        self.name = name
        capacity = count
        self.clock = clock
        entries = (0..<count).map { (key: "e\($0)", used: clock.now) }
    }

    /// The entries' names, least recently used first.
    var keys: [String] { entries.map(\.key) }

    /// Marks `key` used now.
    func use(_ key: String) {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return }
        entries.remove(at: index)
        entries.append((key: key, used: clock.now))
    }

    func updateMemoryLimit(_ limit: MemoryLimit) {
        limits.append(limit.percent)
    }

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        releasePasses += 1
        let inUse = entries.count(where: { isInUse($0.used) })
        let keep = slice.limit.scale(capacity, inUse: inUse)
        while entries.count > keep, let oldest = entries.first {
            if slice.isExpired { return .more }
            if isInUse(oldest.used) { releasedInUse += 1 }
            entries.removeFirst()
        }
        let keptInUseIdle = entries.filter { isInUse($0.used) }.map { $0.used.duration(to: clock.now) }.max()
        return .finished(keptInUseIdleFor: keptInUseIdle)
    }

    var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: entries.count * 1_024, entries: entries.count)
    }

    private func isInUse(_ used: ManualClock.Instant) -> Bool {
        MemoryLimit.isInWorkingSet(idle: used.duration(to: clock.now))
    }
}
