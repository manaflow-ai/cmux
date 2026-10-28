import CmuxNextCompat
@testable import CmuxNextMemory
import Testing

/// ``MemoryCoordinator`` sets limits from the pressure level and the Memory Saver mode, releases on
/// later frames in trait order inside the slice budget, and makes no call it does not need. Time is
/// a ``ManualClock`` that only consumer work advances; frames are a ``ManualSlicer`` the test fires.
@MainActor @Suite struct MemoryCoordinatorTests {
    let clock = ManualClock()
    let log = CallLog()
    let source: ManualMemoryPressureSource
    let pressure: MemoryPressureEvents
    let slicer: ManualSlicer
    let coordinator: MemoryCoordinator

    init() {
        self.init(initial: .normal)
    }

    init(initial: MemoryPressureLevel, mode: MemorySaverMode = .medium) {
        source = ManualMemoryPressureSource(initial: initial)
        pressure = MemoryPressureEvents(source: source)
        slicer = ManualSlicer(clock: clock)
        coordinator = MemoryCoordinator(pressure: pressure, mode: mode, slicer: slicer, clock: clock)
    }

    func consumer(_ name: String, entries: Int = 4, costPerEntry: Duration = .microseconds(100)) -> RecordingConsumer {
        RecordingConsumer(name: name, entries: entries, costPerEntry: costPerEntry, clock: clock, log: log)
    }

    func register(_ consumer: RecordingConsumer, _ traits: MemoryConsumerTraits) -> MemoryConsumerRegistration {
        MemoryConsumerRegistration(name: consumer.name, traits: traits, consumer: consumer, registry: coordinator)
    }

    @Test func releasesCheapMemoryFirstAndLossyPlannersLast() {
        let lossy = consumer("lossy")
        let reads = consumer("reads")
        let expensive = consumer("memory-expensive")
        let cheap = consumer("memory-cheap")
        let disk = consumer("disk")
        // Registered in the reverse of the release order.
        let registrations = [
            register(lossy, managedTraits(retention: .lossy, recreateCost: .expensive)),
            register(disk, managedTraits(dataAccess: .readsAndWritesDisk)),
            register(reads, managedTraits(dataAccess: .reads)),
            register(expensive, managedTraits(recreateCost: .expensive)),
            register(cheap, managedTraits()),
        ]
        log.clear()
        source.send(.critical)
        slicer.drain()
        #expect(log.releases == ["memory-cheap", "memory-expensive", "reads", "disk", "lossy"])
        withExtendedLifetime(registrations) {}
    }

    @Test func withinATierLowCPUCostAndLargerConsumersReleaseFirst() {
        let smallLow = consumer("small-low")
        let largeHigh = consumer("large-high")
        let largeLow = consumer("large-low")
        let registrations = [
            register(smallLow, managedTraits(estimatedUsage: .small)),
            register(largeHigh, managedTraits(releaseCPUCost: .high, estimatedUsage: .large)),
            register(largeLow, managedTraits(estimatedUsage: .large)),
        ]
        source.send(.critical)
        slicer.drain()
        #expect(log.releases == ["large-low", "small-low", "large-high"])
        withExtendedLifetime(registrations) {}
    }

    @Test func noSliceRunsOverItsBudget() {
        // 3 consumers of 100 entries at 0.25 ms each: 75 ms of work, 8 entries a frame, 38 frames.
        let consumers = (0..<3).map { consumer("c\($0)", entries: 100, costPerEntry: .microseconds(250)) }
        let registrations = consumers.map { register($0, managedTraits()) }
        source.send(.critical)
        let frames = slicer.drain()
        #expect(frames >= 38, "the work was not cut into slices")
        #expect(slicer.frameDurations.allSatisfy { $0 <= MemoryCoordinator.sliceBudget },
                "a slice ran over \(MemoryCoordinator.sliceBudget): \(slicer.frameDurations.max() ?? .zero)")
        #expect(consumers.allSatisfy { $0.entries == 0 }, "critical left entries behind")
        withExtendedLifetime(registrations) {}
    }

    @Test func aRepeatedLevelMakesNoCall() {
        let cheap = consumer("cheap")
        let registration = register(cheap, managedTraits())
        source.send(.warning)
        slicer.drain()
        log.clear()
        let requests = slicer.requests
        source.send(.warning)
        slicer.drain()
        #expect(log.calls.isEmpty, "a repeated level called consumers: \(log.calls)")
        #expect(slicer.requests == requests, "a repeated level asked for a slice")
        withExtendedLifetime(registration) {}
    }

    @Test func criticalThenNormalBeforeTheFrameMakesNoReleaseCall() {
        let cheap = consumer("cheap")
        let lossy = consumer("lossy")
        let registrations = [register(cheap, managedTraits()), register(lossy, managedTraits(retention: .lossy))]
        source.send(.critical)
        source.send(.normal)
        slicer.drain()
        #expect(log.releases.isEmpty, "a level that came back still released: \(log.releases)")
        #expect(cheap.entries == 4 && lossy.entries == 4)
        #expect(cheap.limit == .default && lossy.limit == .default)
        withExtendedLifetime(registrations) {}
    }

    @Test func theFirstSliceIsNotInTheEventTurn() {
        let cheap = consumer("cheap")
        let registration = register(cheap, managedTraits())
        log.clear()
        source.send(.critical)
        #expect(log.calls == [.limit("cheap", 0)], "the event turn did more than set the limit")
        #expect(slicer.hasPendingSlice)
        slicer.fireFrame()
        #expect(log.releases == ["cheap"])
        withExtendedLifetime(registration) {}
    }

    @Test func aConsumerRegisteredMidReleaseGetsTheCurrentLimitAtOnce() {
        let big = consumer("big", entries: 100, costPerEntry: .microseconds(500))
        let registration = register(big, managedTraits())
        source.send(.critical)
        slicer.fireFrame()
        #expect(big.entries > 0, "the release finished in one frame; the test needs it in progress")

        let late = consumer("late")
        let lateRegistration = register(late, managedTraits())
        #expect(late.limit == .criticalThreshold, "a registrant mid-release did not get the current limit at once")

        // And one that registers from inside a consumer's release call.
        let inner = consumer("inner")
        var innerRegistration: MemoryConsumerRegistration?
        big.duringNextRelease = { innerRegistration = register(inner, managedTraits()) }
        slicer.fireFrame()
        #expect(inner.limit == .criticalThreshold)

        slicer.drain()
        #expect(big.entries == 0 && late.entries == 0 && inner.entries == 0, "a late registrant was not released")
        withExtendedLifetime((registration, lateRegistration, innerRegistration)) {}
    }

    @Test func theInitialLevelComesFromTheSourceBeforeAnyEvent() {
        let critical = MemoryCoordinatorTests(initial: .critical)
        #expect(critical.coordinator.level == .critical)
        let cheap = critical.consumer("cheap")
        let registration = critical.register(cheap, managedTraits())
        #expect(cheap.limit == .criticalThreshold)
        critical.slicer.drain()
        #expect(cheap.entries == 0)
        withExtendedLifetime(registration) {}
    }

    @Test func warningScalesOnlyCheapMemoryOnlyConsumersByTheModeShare() {
        let cheap = consumer("cheap")
        let reads = consumer("reads")
        let expensive = consumer("expensive")
        let lossy = consumer("lossy")
        let registrations = [
            register(cheap, managedTraits()),
            register(reads, managedTraits(dataAccess: .reads)),
            register(expensive, managedTraits(recreateCost: .expensive)),
            register(lossy, managedTraits(retention: .lossy)),
        ]
        source.send(.warning)
        #expect(cheap.limit == MemoryLimit(percent: 25), "medium share x 1/2")
        #expect(reads.limit == .default && expensive.limit == .default && lossy.limit == .default)
        slicer.drain()
        #expect(log.releases == ["cheap"])
        #expect(cheap.entries == 1)

        coordinator.mode = .conservative
        #expect(cheap.limit == MemoryLimit(percent: 37))
        coordinator.mode = .off
        #expect(cheap.limit == MemoryLimit(percent: 50))
        withExtendedLifetime(registrations) {}
    }

    @Test func unmanagedConsumersKeepTheirSizeAtWarningAndGetTheLevelAtCritical() {
        let stateless = consumer("stateless")
        let registration = register(stateless, MemoryConsumerTraits(
            estimatedUsage: .large, dataAccess: .none, retention: .lossy, recreateCost: .expensive,
            releaseCPUCost: .low, isStateful: false, supportsMemoryLimit: false))
        source.send(.warning)
        #expect(stateless.limit == .default)
        source.send(.critical)
        #expect(stateless.limit == .criticalThreshold)
        withExtendedLifetime(registration) {}
    }

    @Test func normalIsTheFullSizeInEveryMode() {
        for mode in MemorySaverMode.allCases {
            let policy = MemoryLimitPolicy(mode: mode)
            #expect(policy.limit(for: managedTraits(), at: .normal) == .default)
            #expect(policy.limit(for: managedTraits(), at: .critical) == .criticalThreshold)
        }
        #expect(MemoryLimitPolicy(mode: .aggressive).limit(for: managedTraits(), at: .warning) == MemoryLimit(percent: 12))
    }

    @Test func theOverrideReplacesTheKernelLevelUntilCleared() {
        let cheap = consumer("cheap")
        let registration = register(cheap, managedTraits())
        coordinator.pressureOverride = .critical
        #expect(coordinator.level == .critical && cheap.limit == .criticalThreshold)
        source.send(.warning)
        #expect(coordinator.level == .critical, "a kernel event broke through the override")
        #expect(coordinator.kernelLevel == .warning)
        coordinator.pressureOverride = nil
        #expect(coordinator.level == .warning && cheap.limit == MemoryLimit(percent: 25))
        withExtendedLifetime(registration) {}
    }

    @Test func aReleasedRegistrationIsNeverCalledAgain() {
        let cheap = consumer("cheap")
        var registration: MemoryConsumerRegistration? = register(cheap, managedTraits())
        registration = nil
        log.clear()
        source.send(.critical)
        slicer.drain()
        #expect(registration == nil)
        #expect(log.calls.isEmpty, "a released consumer was called: \(log.calls)")
    }

    @Test func equalOrdersReleaseInRegistrationOrder() {
        let consumers = (0..<4).map { consumer("c\($0)") }
        let registrations = consumers.map { register($0, managedTraits()) }
        source.send(.critical)
        slicer.drain()
        #expect(log.releases == ["c0", "c1", "c2", "c3"])
        withExtendedLifetime(registrations) {}
    }

    @Test func registrationsThatComeAndGoNeverGrowTheCoordinator() {
        let kept = consumer("kept")
        let registration = register(kept, managedTraits())
        for index in 0..<100 {
            _ = register(consumer("gone\(index)"), managedTraits())
        }
        #expect(coordinator.consumers.storedCount <= 2, "released registrations stayed in the coordinator")
        source.send(.critical)
        slicer.drain()
        #expect(coordinator.consumers.storedCount == 1)
        #expect(coordinator.consumers.liveEntries().map(\.name) == ["kept"])
        #expect(log.releases == ["kept"], "a released registration was called")
        withExtendedLifetime(registration) {}
    }

    /// A consumer that frees one item per frame (a warm surface) and yields leaves the
    /// rest of the slice to the consumers after it: a lossy pass ordered last runs on the first frame,
    /// not after 30 frames of single closes.
    @Test func aYieldingConsumerLeavesTheRestOfTheSliceToTheNext() {
        let paced = PacedConsumer(name: "paced", entries: 30, log: log)
        let lossy = consumer("lossy")
        let registrations = [
            MemoryConsumerRegistration(name: paced.name, traits: managedTraits(), consumer: paced, registry: coordinator),
            register(lossy, managedTraits(retention: .lossy, recreateCost: .expensive)),
        ]
        log.clear()
        source.send(.critical)
        slicer.fireFrame()
        #expect(log.releases == ["paced", "lossy"], "the consumer after a yielding one waited for a later frame")
        #expect(paced.entries == 29, "a yielding consumer freed more than its one item in a slice")
        let frames = slicer.drain()
        #expect(frames == 29)
        #expect(paced.entries == 0)
        #expect(log.releases.filter { $0 == "lossy" }.count == 1, "a consumer that finished was called again")
        withExtendedLifetime(registrations) {}
    }

    @Test func aLimitRaisedDuringAReleaseKeepsWhatIsHeld() {
        let big = consumer("big", entries: 100, costPerEntry: .microseconds(500))
        let registration = register(big, managedTraits())
        source.send(.critical)
        slicer.fireFrame()
        let left = big.entries
        source.send(.normal)
        let releases = log.releases.count
        slicer.drain()
        #expect(log.releases.count == releases, "normal kept releasing")
        #expect(big.entries == left)
        withExtendedLifetime(registration) {}
    }
}
