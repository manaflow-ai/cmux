import CmuxNextCompat
import CmuxNextMemory
import Darwin
import Dispatch
import Testing

/// ``MemoryReleaseSink`` ends what release slices unlinked on its own queue, never on main, and the
/// coordinator asks it for exactly one heap relief per escalation to critical, after that pass's
/// drops. Frames are a ``ManualSlicer`` the test fires; the relief is an injected recorder.
@MainActor @Suite struct MemoryReleaseSinkTests {
    let clock = ManualClock()
    let source = ManualMemoryPressureSource(initial: .normal)
    let pressure: MemoryPressureEvents
    let slicer: ManualSlicer
    let deinits: ReleaseThreadLog
    let reliefs: ReleaseThreadLog
    let queueLabel: String
    let sink: MemoryReleaseSink
    let coordinator: MemoryCoordinator

    init() {
        pressure = MemoryPressureEvents(source: source)
        slicer = ManualSlicer(clock: clock)
        let label = "cmux.test.memory.release-sink.\(UInt64.random(in: 0 ... .max))"
        queueLabel = label
        let reliefs = ReleaseThreadLog()
        let deinits = ReleaseThreadLog()
        self.reliefs = reliefs
        self.deinits = deinits
        sink = MemoryReleaseSink(
            queue: DispatchQueue(label: label, qos: .utility),
            heapRelief: .init { reliefs.record(endedBefore: deinits.count) })
        coordinator = MemoryCoordinator(pressure: pressure, slicer: slicer, clock: clock, releaseSink: sink)
    }

    func dropping(_ entries: Int, costPerEntry: Duration = .microseconds(100)) -> DroppingConsumer {
        DroppingConsumer(entries: entries, costPerEntry: costPerEntry, log: deinits, sink: sink, clock: clock)
    }

    func register(_ consumer: DroppingConsumer) -> MemoryConsumerRegistration {
        MemoryConsumerRegistration(name: "dropping", traits: managedTraits(), consumer: consumer, registry: coordinator)
    }

    @Test func aDroppedValueEndsOnTheSinkQueueNotOnMain() async {
        sink.drop(DeinitProbe(deinits))
        sink.drop(DeinitProbe(deinits))
        await sink.drained()
        #expect(deinits.count == 2)
        #expect(deinits.events.allSatisfy { !$0.onMain && $0.queue == queueLabel }, "a value ended on main: \(deinits.events)")
    }

    @Test func aCriticalReleaseEndsEveryEntryOffMain() async {
        let consumer = dropping(40, costPerEntry: .microseconds(300))
        let registration = register(consumer)
        source.send(.critical)
        let frames = slicer.drain()
        #expect(frames > 1, "the release fit one frame; the test needs it sliced")
        #expect(consumer.held == 0)
        await sink.drained()
        #expect(deinits.count == 40)
        #expect(deinits.events.allSatisfy { !$0.onMain && $0.queue == queueLabel }, "an entry ended on main: \(deinits.events)")
        withExtendedLifetime(registration) {}
    }

    @Test func oneReliefPerEscalationToCriticalAndNoneAtWarningOrARepeatedLevel() async {
        let consumer = dropping(4)
        let registration = register(consumer)
        source.send(.warning)
        #expect(slicer.drain() > 0, "warning ran no release pass")
        await sink.drained()
        #expect(consumer.held < 4, "warning released nothing; the test needs a pass that drops")
        #expect(deinits.count == 4 - consumer.held)
        #expect(reliefs.count == 0, "warning relieved the heap")

        source.send(.critical)
        slicer.drain()
        await sink.drained()
        #expect(reliefs.count == 1)

        source.send(.critical)
        slicer.drain()
        await sink.drained()
        #expect(reliefs.count == 1, "a repeated critical relieved the heap again")

        source.send(.normal)
        slicer.drain()
        source.send(.critical)
        slicer.drain()
        await sink.drained()
        #expect(reliefs.count == 2, "a second escalation to critical did not relieve the heap")
        #expect(reliefs.events.allSatisfy { !$0.onMain && $0.queue == queueLabel }, "a relief ran on main: \(reliefs.events)")
        withExtendedLifetime((registration, consumer)) {}
    }

    @Test func theReliefRunsAfterThePassAndAfterItsDrops() async {
        let consumer = dropping(40, costPerEntry: .microseconds(300))
        let registration = register(consumer)
        source.send(.critical)
        slicer.fireFrame()
        await sink.drained()
        #expect(consumer.held > 0, "the release finished in one frame; the test needs it in progress")
        #expect(reliefs.count == 0, "the heap was relieved before the pass finished")

        slicer.drain()
        await sink.drained()
        #expect(reliefs.count == 1)
        #expect(reliefs.endedBefore == [40], "the relief ran before the pass's drops ended")
        withExtendedLifetime(registration) {}
    }

    @Test func aLateRegistrantKeepsThePassOpenUntilItIsReleased() async {
        let first = dropping(2)
        let late = dropping(3)
        var lateRegistration: MemoryConsumerRegistration?
        first.duringNextRelease = { lateRegistration = register(late) }
        let registration = register(first)
        source.send(.critical)
        slicer.drain()
        await sink.drained()
        #expect(late.held == 0)
        #expect(reliefs.endedBefore == [5], "the relief ran before the late registrant's drops")
        withExtendedLifetime((registration, lateRegistration)) {}
    }

    @Test func criticalThatEndsBeforeThePassFinishesRelievesNothing() async {
        let consumer = dropping(40, costPerEntry: .microseconds(300))
        let registration = register(consumer)
        source.send(.critical)
        source.send(.normal)
        slicer.drain()
        await sink.drained()
        #expect(reliefs.count == 0)

        source.send(.critical)
        slicer.fireFrame()
        source.send(.warning)
        slicer.drain()
        await sink.drained()
        #expect(reliefs.count == 0, "a pass that left critical still relieved the heap")
        withExtendedLifetime(registration) {}
    }

    @Test func criticalWithNothingToReleaseRelievesOnceOnTheNextFrame() async {
        source.send(.critical)
        await sink.drained()
        #expect(reliefs.count == 0, "the relief was asked for in the event turn")
        #expect(slicer.hasPendingSlice)
        slicer.drain()
        await sink.drained()
        #expect(reliefs.count == 1)
    }

    @Test func theDebugOverrideEscalatesLikeTheKernel() async {
        let consumer = dropping(4)
        let registration = register(consumer)
        coordinator.pressureOverride = .critical
        slicer.drain()
        await sink.drained()
        #expect(consumer.held < 4, "the override's critical released nothing")
        #expect(reliefs.count == 1)
        #expect(reliefs.endedBefore == [4 - consumer.held], "the relief ran before the pass's drops ended")
        source.send(.critical)
        slicer.drain()
        await sink.drained()
        #expect(reliefs.count == 1, "the kernel's critical under a critical override relieved again")
        withExtendedLifetime((registration, consumer)) {}
    }

    @Test func theAppSinkRunsAtUtilityQoS() async {
        let qos = ReleaseThreadLog()
        let appSink = MemoryReleaseSink(heapRelief: .init { qos.record(endedBefore: 0) })
        appSink.relieveHeap()
        await appSink.drained()
        #expect(qos.events.map(\.qos) == [QOS_CLASS_UTILITY.rawValue])
        #expect(qos.events.allSatisfy { !$0.onMain })
    }
}

/// What ran on which thread: deinits of ``DeinitProbe`` or heap reliefs.
nonisolated final class ReleaseThreadLog: Sendable {
    nonisolated struct Event: Sendable {
        let onMain: Bool
        let queue: String
        let qos: UInt32
        /// For a relief: how many probes had ended when it ran.
        let endedBefore: Int
    }

    // Probes end and reliefs run on the sink's queue; the test reads on main after drained().
    private let log = Mutex<[Event]>([])

    func record(endedBefore: Int = 0) {
        let event = Event(
            onMain: pthread_main_np() != 0, queue: String(cString: __dispatch_queue_get_label(nil)),
            qos: qos_class_self().rawValue, endedBefore: endedBefore)
        log.withLock { $0.append(event) }
    }

    var events: [Event] { log.withLock { $0 } }
    var count: Int { log.withLock { $0.count } }
    var endedBefore: [Int] { events.map(\.endedBefore) }
}

/// A dropped entry that records the thread its deinit ran on.
nonisolated final class DeinitProbe: Sendable {
    private let log: ReleaseThreadLog

    init(_ log: ReleaseThreadLog) {
        self.log = log
    }

    deinit {
        log.record()
    }
}

/// A consumer that holds probes and, like a real cache, only unlinks them in a slice: each one goes
/// to the sink. Each entry costs `costPerEntry` of clock time.
@MainActor
final class DroppingConsumer: MemoryConsumer {
    static let footprintPerEntry = 1_024
    private var probes: [DeinitProbe]
    private let full: Int
    private let costPerEntry: Duration
    private let sink: any MemoryReleaseSinking
    private let clock: ManualClock
    /// Runs inside the next release call, once.
    var duringNextRelease: (@MainActor () -> Void)?

    init(entries: Int, costPerEntry: Duration, log: ReleaseThreadLog, sink: any MemoryReleaseSinking, clock: ManualClock) {
        probes = (0 ..< entries).map { _ in DeinitProbe(log) }
        full = entries
        self.costPerEntry = costPerEntry
        self.sink = sink
        self.clock = clock
    }

    var held: Int { probes.count }

    func updateMemoryLimit(_ limit: MemoryLimit) {}

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        if let hook = duringNextRelease {
            duringNextRelease = nil
            hook()
        }
        let cap = slice.limit.scale(full)
        while probes.count > cap {
            if slice.isExpired { return .more }
            sink.drop(probes.removeLast())
            clock.advance(by: costPerEntry)
        }
        return .done
    }

    var memoryUsage: MemoryUsage? {
        MemoryUsage(
            footprintBytes: probes.count * Self.footprintPerEntry, volatileBytes: probes.count * 4 * Self.footprintPerEntry,
            entries: probes.count)
    }
}
