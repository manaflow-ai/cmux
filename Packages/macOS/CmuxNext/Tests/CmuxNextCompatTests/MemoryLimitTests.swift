import CmuxNextCompat
import Foundation
import Testing

/// The memory coordinator's protocol values (CmuxNextCompat/Memory, a port of Chrome's
/// base/memory_coordinator): a ``MemoryLimit`` scales a consumer's full size and clamps to 0...100,
/// the default is 100 %, each ``MemorySaverMode`` has Chrome's share, and a
/// ``MemoryConsumerRegistration`` hands its consumer the current limit at once and stops the
/// registry's calls when it is cancelled or released, on the main thread or another one.
@MainActor @Suite struct MemoryLimitTests {
    // MARK: MemoryLimit

    @Test func theDefaultIsTheFullSize() {
        #expect(MemoryLimit.default.percent == 100)
        #expect(MemoryLimit.default.ratio == 1)
        #expect(MemoryLimit.default.scale(64 << 20) == 64 << 20)
        #expect(!MemoryLimit.default.isCritical)
    }

    @Test func aLimitScalesBytesAndEntriesRoundingDown() {
        let half = MemoryLimit(percent: 50)
        #expect(half.scale(64 << 20) == 32 << 20)
        #expect(half.scale(5) == 2)
        #expect(MemoryLimit(percent: 75).scale(48 << 20) == 36 << 20)
        #expect(MemoryLimit(percent: 25).scale(3) == 0)
        #expect(MemoryLimit(percent: 0).scale(1 << 30) == 0)
        #expect(MemoryLimit(percent: 33).scale(1000) == 330)
    }

    @Test func scalingNeverOverflowsAndTreatsANegativeSizeAsZero() {
        #expect(MemoryLimit.default.scale(Int.max) == Int.max)
        #expect(MemoryLimit(percent: 50).scale(Int.max) == Int.max / 2)
        #expect(MemoryLimit(percent: 50).scale(-10) == 0)
    }

    @Test func percentagesClampToZeroThroughOneHundred() {
        #expect(MemoryLimit(percent: 150) == .default)
        #expect(MemoryLimit(percent: -5).percent == 0)
        #expect(MemoryLimit(percent: -5).isCritical)
    }

    @Test func theCriticalThresholdIsZeroAndOnlyItIsCritical() {
        #expect(MemoryLimit.criticalThreshold.percent == 0)
        #expect(MemoryLimit.criticalThreshold.isCritical)
        #expect(!MemoryLimit(percent: 1).isCritical)
        #expect(MemoryLimit(percent: 1) > .criticalThreshold)
    }

    @Test func aLimitAppliedOnAShareMultipliesRoundingDown() {
        #expect(MemoryLimit(percent: 50).scaled(by: MemorySaverMode.conservative.share).percent == 37)
        #expect(MemoryLimit.default.scaled(by: MemorySaverMode.aggressive.share).percent == 25)
        #expect(MemoryLimit(percent: 50).scaled(by: MemorySaverMode.off.share).percent == 50)
    }

    @Test func aLimitCodesAsABarePercentageAndClampsWhatItReads() throws {
        let data = try JSONEncoder().encode(MemoryLimit(percent: 42))
        #expect(String(decoding: data, as: UTF8.self) == "42")
        #expect(try JSONDecoder().decode(MemoryLimit.self, from: data).percent == 42)
        #expect(try JSONDecoder().decode(MemoryLimit.self, from: Data("250".utf8)) == .default)
    }

    // MARK: MemorySaverMode

    @Test func eachModeHasChromesShare() {
        let shares = MemorySaverMode.allCases.map { "\($0.rawValue)=\($0.share.percent)" }
        #expect(shares == ["off=100", "conservative=75", "medium=50", "aggressive=25"])
    }

    // MARK: MemoryConsumerTraits

    @Test func onlyStatefulConsumersThatSupportALimitAreManaged() {
        #expect(Self.traits(isStateful: true, supportsMemoryLimit: true).isManaged)
        #expect(!Self.traits(isStateful: false, supportsMemoryLimit: true).isManaged)
        #expect(!Self.traits(isStateful: true, supportsMemoryLimit: false).isManaged)
    }

    // MARK: MemoryReleaseSlice

    @Test func aSliceEndsWhenItsBudgetIsUsed() {
        let spent = MemoryReleaseSlice(limit: .criticalThreshold, clock: ContinuousClock(), budget: .zero)
        let open = MemoryReleaseSlice(limit: .criticalThreshold, clock: ContinuousClock(), budget: .seconds(3600))
        #expect(spent.isExpired)
        #expect(!open.isExpired)
        #expect(open.limit == .criticalThreshold)
    }

    @Test func aConsumerStopsAtTheSliceEndAndFinishesOnALaterTurn() {
        let consumer = RecordingConsumer(entries: 5)
        let turns = Turns(allowed: 2)
        let first = consumer.releaseMemory(within: MemoryReleaseSlice(limit: .criticalThreshold) { turns.take() })
        #expect(first == .more)
        #expect(consumer.entries == 3)
        let second = consumer.releaseMemory(within: MemoryReleaseSlice(limit: .criticalThreshold) { false })
        #expect(second == .done)
        #expect(consumer.entries == 0)
    }

    // MARK: MemoryConsumerRegistration

    @Test func aNewRegistrationGetsTheCurrentLimitBeforeItsInitReturns() {
        let registry = RecordingRegistry(limit: MemoryLimit(percent: 50))
        let consumer = RecordingConsumer(entries: 0)
        let registration = Self.register(consumer, in: registry)
        #expect(consumer.limits == [MemoryLimit(percent: 50)])
        #expect(registry.live.map(\.name) == ["recording"])
        #expect(registration.entry.traits.isManaged)
    }

    @Test func aCancelledRegistrationIsNoLongerCalled() {
        let registry = RecordingRegistry(limit: .default)
        let consumer = RecordingConsumer(entries: 0)
        let registration = Self.register(consumer, in: registry)
        registration.cancel()
        registration.cancel()
        #expect(registration.entry.liveConsumer == nil)
        registry.push(.criticalThreshold)
        #expect(consumer.limits == [.default], "a cancelled consumer still got a limit")
        #expect(registry.live.isEmpty)
    }

    @Test func aReleasedRegistrationIsNoLongerCalled() {
        let registry = RecordingRegistry(limit: .default)
        let consumer = RecordingConsumer(entries: 0)
        var registration: MemoryConsumerRegistration? = Self.register(consumer, in: registry)
        let entry = registration?.entry
        registration = nil
        #expect(registration == nil)
        #expect(entry?.isLive == false)
        registry.push(.criticalThreshold)
        #expect(consumer.limits == [.default], "a released consumer still got a limit")
    }

    @Test func aRegistrationReleasedOffTheMainThreadIsNoLongerCalled() async {
        let registry = RecordingRegistry(limit: .default)
        let consumer = RecordingConsumer(entries: 0)
        let box = RegistrationBox(Self.register(consumer, in: registry))
        let entry = box.entry
        await Task.detached(priority: .utility) { box.release() }.value
        #expect(entry.isLive == false)
        registry.push(.criticalThreshold)
        #expect(consumer.limits == [.default], "a consumer released off main still got a limit")
    }

    @Test func aConsumerThatWentIsNoLongerCalledAndTheRegistrationHoldsItWeakly() {
        let registry = RecordingRegistry(limit: .default)
        var consumer: RecordingConsumer? = RecordingConsumer(entries: 0)
        weak let weakConsumer = consumer
        let registration = consumer.map { Self.register($0, in: registry) }
        consumer = nil
        #expect(weakConsumer == nil, "the registration kept its consumer alive")
        #expect(registration?.entry.isLive == false)
        withExtendedLifetime(registration) {}
    }

    // MARK: Helpers

    static func traits(isStateful: Bool = true, supportsMemoryLimit: Bool = true) -> MemoryConsumerTraits {
        MemoryConsumerTraits(
            estimatedUsage: .medium, dataAccess: .none, retention: .lossless, recreateCost: .cheap,
            releaseCPUCost: .low, isStateful: isStateful, supportsMemoryLimit: supportsMemoryLimit)
    }

    static func register(_ consumer: RecordingConsumer, in registry: RecordingRegistry) -> MemoryConsumerRegistration {
        MemoryConsumerRegistration(name: "recording", traits: traits(), consumer: consumer, registry: registry)
    }
}

/// A consumer that records each limit and releases one entry per slice check.
final class RecordingConsumer: MemoryConsumer {
    private(set) var limits: [MemoryLimit] = []
    private(set) var entries: Int

    init(entries: Int) {
        self.entries = entries
    }

    func updateMemoryLimit(_ limit: MemoryLimit) {
        limits.append(limit)
    }

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        let keep = slice.limit.scale(entries)
        while entries > keep {
            if slice.isExpired { return .more }
            entries -= 1
        }
        return .done
    }

    var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: entries * 1024, entries: entries)
    }
}

/// A registry that hands each new consumer its one limit and pushes later limits to live ones.
final class RecordingRegistry: MemoryConsumerRegistry {
    private var entries: [MemoryConsumerEntry] = []
    private var limit: MemoryLimit

    init(limit: MemoryLimit) {
        self.limit = limit
    }

    func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
        entries.removeAll { !$0.isLive }
        entries.append(entry)
        entry.liveConsumer?.updateMemoryLimit(limit)
    }

    /// The live entries, released ones dropped.
    var live: [MemoryConsumerEntry] {
        entries.removeAll { !$0.isLive }
        return entries
    }

    func push(_ newLimit: MemoryLimit) {
        limit = newLimit
        for entry in live { entry.liveConsumer?.updateMemoryLimit(newLimit) }
    }
}

/// Lets a slice run `allowed` checks, then ends it (the slice's check is a `@Sendable` closure).
nonisolated final class Turns: Sendable {
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

/// Holds the only reference to a registration so another thread can release it.
nonisolated final class RegistrationBox: Sendable {
    private let registration: Mutex<MemoryConsumerRegistration?>
    let entry: MemoryConsumerEntry

    @MainActor init(_ registration: MemoryConsumerRegistration) {
        entry = registration.entry
        self.registration = Mutex(registration)
    }

    func release() {
        registration.withLock { $0 = nil }
    }
}
