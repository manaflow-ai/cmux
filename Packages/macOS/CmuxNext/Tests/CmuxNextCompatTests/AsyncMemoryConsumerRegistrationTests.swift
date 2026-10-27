import CmuxNextCompat
import Dispatch
import Testing

/// ``AsyncMemoryConsumerRegistration`` (a port of Chrome's
/// base/memory_coordinator/async_memory_consumer_registration.h): a consumer on its own actor gets
/// the registry's calls on that actor, a registration dropped before the hop runs is never called,
/// and the main actor pays one enqueue per slice whatever the registry calls in it. The time limit
/// turns a lost delivery into a failure instead of a hung `for await`.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AsyncMemoryConsumerRegistrationTests {
    @Test func aConsumerOnItsOwnActorGetsBothCallsOnThatActor() async {
        let registry = RecordingRegistry(limit: MemoryLimit(percent: 50))
        let consumer = QueueActorConsumer(entries: 10)
        let registration = Self.register(consumer, in: registry)

        var events: [QueueActorConsumer.Event] = []
        for await event in consumer.events {
            events.append(event)
            if events.count == 1 {
                _ = registration.entry.liveConsumer?.releaseMemory(within: Self.slice(.criticalThreshold))
            }
            if events.count == 2 { break }
        }

        #expect(events == [
            .init(call: .update, limit: MemoryLimit(percent: 50), onActorQueue: true),
            .init(call: .release, limit: .criticalThreshold, onActorQueue: true),
        ])
        withExtendedLifetime(registration) {}
    }

    @Test func aMutexConsumerGetsTheCurrentLimitAndReportsItsLastUsage() async {
        let hops = HopRecorder()
        let registry = RecordingRegistry(limit: MemoryLimit(percent: 75))
        let consumer = MutexConsumer(entries: 8)
        let registration = Self.register(consumer, in: registry, hop: hops.hop)
        #expect(registration.entry.liveConsumer?.memoryUsage == nil, "a usage before the first call")

        await hops.runAll()
        #expect(consumer.calls == [.update(MemoryLimit(percent: 75))])
        #expect(registration.entry.liveConsumer?.memoryUsage == MemoryUsage(footprintBytes: 8 * 1024, entries: 8))

        _ = registration.entry.liveConsumer?.releaseMemory(within: Self.slice(MemoryLimit(percent: 50)))
        await hops.runAll()
        #expect(consumer.calls == [.update(MemoryLimit(percent: 75)), .release(MemoryLimit(percent: 50))])
        #expect(registration.entry.liveConsumer?.memoryUsage == MemoryUsage(footprintBytes: 4 * 1024, entries: 4))
    }

    @Test func aRegistrationCancelledBeforeTheHopIsNotCalled() async {
        let hops = HopRecorder()
        let registry = RecordingRegistry(limit: .default)
        let consumer = MutexConsumer(entries: 4)
        let registration = Self.register(consumer, in: registry, hop: hops.hop)
        #expect(hops.pending == 1)

        registration.cancel()
        await hops.runAll()
        #expect(consumer.calls.isEmpty, "a cancelled registration still reached its consumer")
        #expect(registration.entry.liveConsumer == nil)

        registry.push(.criticalThreshold)
        #expect(hops.pending == 0, "a cancelled registration still posted a delivery")
    }

    @Test func aRegistrationReleasedBeforeTheHopIsNotCalled() async {
        let hops = HopRecorder()
        let registry = RecordingRegistry(limit: .default)
        let consumer = MutexConsumer(entries: 4)
        var registration: AsyncMemoryConsumerRegistration? = Self.register(consumer, in: registry, hop: hops.hop)
        let entry = registration?.entry
        registration = nil

        #expect(registration == nil)
        #expect(entry?.isLive == false)
        await hops.runAll()
        #expect(consumer.calls.isEmpty, "a released registration still reached its consumer")
    }

    @Test func aConsumerThatWentBeforeTheHopIsNotCalledAndIsHeldWeakly() async {
        let hops = HopRecorder()
        let registry = RecordingRegistry(limit: .default)
        var consumer: MutexConsumer? = MutexConsumer(entries: 4)
        weak let weakConsumer = consumer
        let registration = consumer.map { Self.register($0, in: registry, hop: hops.hop) }
        consumer = nil

        #expect(weakConsumer == nil, "the registration kept its consumer alive")
        #expect(registration?.entry.isLive == false, "a gone consumer's entry stayed live")
        await hops.runAll()
        #expect(registration?.entry.liveConsumer?.memoryUsage == nil)
    }

    @Test func aConsumerThatWentAfterItsFirstCallIsNoLongerLiveOrReported() async {
        let hops = HopRecorder()
        let registry = RecordingRegistry(limit: .default)
        var consumer: MutexConsumer? = MutexConsumer(entries: 8)
        weak let weakConsumer = consumer
        let registration = consumer.map { Self.register($0, in: registry, hop: hops.hop) }
        await hops.runAll()
        #expect(registration?.entry.liveConsumer?.memoryUsage == MemoryUsage(footprintBytes: 8 * 1024, entries: 8))

        consumer = nil
        #expect(weakConsumer == nil, "the registration kept its consumer alive")
        #expect(registration?.entry.isLive == false, "a gone consumer's entry stayed live")
        #expect(registration?.entry.liveConsumer?.memoryUsage == nil, "a gone consumer still reported its last usage")
        #expect(registry.live.isEmpty, "the registry kept a gone consumer's entry")
        registry.push(.criticalThreshold)
        #expect(hops.pending == 0, "a gone consumer still got a delivery")
        withExtendedLifetime(registration) {}
    }

    @Test func aCancelDuringACallDropsThePendingCallAndTheCallsResult() async {
        let hops = HopRecorder()
        let registry = RecordingRegistry(limit: MemoryLimit(percent: 50))
        let consumer = GatedConsumer()
        let registration = Self.register(consumer, in: registry, hop: hops.hop)
        let delivery = Task { await hops.runAll() }
        for await _ in consumer.entered { break }

        _ = registration.entry.liveConsumer?.releaseMemory(within: Self.slice(.criticalThreshold))
        #expect(hops.pending == 0, "a call during a delivery posted a second one")
        registration.cancel()
        await consumer.open()
        await delivery.value

        #expect(await consumer.calls == [.update(MemoryLimit(percent: 50))], "a pending call reached a cancelled consumer")
        #expect(registration.entry.liveConsumer == nil)
        registry.push(.default)
        #expect(hops.pending == 0, "a cancelled registration still posted a delivery")
    }

    @Test func aRegistrationReleasedOffTheMainThreadIsNoLongerCalled() async {
        let hops = HopRecorder()
        let registry = RecordingRegistry(limit: .default)
        let consumer = MutexConsumer(entries: 4)
        let box = AsyncRegistrationBox(Self.register(consumer, in: registry, hop: hops.hop))
        let entry = box.entry
        await Task.detached(priority: .utility) { box.release() }.value

        #expect(entry.isLive == false)
        await hops.runAll()
        registry.push(.criticalThreshold)
        #expect(consumer.calls.isEmpty, "a consumer released off main still got a call")
        #expect(hops.pending == 0, "a consumer released off main still got a delivery")
    }

    @Test func aMainSliceCostsOneEnqueueAndTheConsumerGetsTheNewestLimitInOrder() async {
        let hops = HopRecorder()
        let registry = RecordingRegistry(limit: .default)
        let consumer = MutexConsumer(entries: 10)
        let registration = Self.register(consumer, in: registry, hop: hops.hop)

        let progress = registration.entry.liveConsumer?.releaseMemory(within: Self.slice(MemoryLimit(percent: 50)))
        registry.push(MemoryLimit(percent: 20))
        #expect(progress == .done, "the main slice waited for the consumer")
        #expect(hops.pending == 1, "each call in the turn posted its own delivery")

        await hops.runAll()
        #expect(consumer.calls == [.update(MemoryLimit(percent: 20)), .release(MemoryLimit(percent: 20))])

        registry.push(MemoryLimit(percent: 60))
        #expect(hops.pending == 1, "no delivery after the last one ended")
        await hops.runAll()
        #expect(consumer.calls.last == .update(MemoryLimit(percent: 60)))
    }

    // MARK: Helpers

    static func register(
        _ consumer: any AsyncMemoryConsumer,
        in registry: RecordingRegistry,
        hop: AsyncMemoryConsumerHop = .task
    ) -> AsyncMemoryConsumerRegistration {
        AsyncMemoryConsumerRegistration(
            name: "async-recording", traits: MemoryLimitTests.traits(), consumer: consumer, registry: registry, hop: hop)
    }

    static func slice(_ limit: MemoryLimit) -> MemoryReleaseSlice {
        MemoryReleaseSlice(limit: limit) { false }
    }
}

/// An actor that runs on its own serial queue and reports, for each call, whether it ran there.
private actor QueueActorConsumer: AsyncMemoryConsumer {
    nonisolated struct Event: Equatable, Sendable {
        nonisolated enum Call: Sendable { case update, release }
        let call: Call
        let limit: MemoryLimit
        let onActorQueue: Bool
    }

    nonisolated let events: AsyncStream<Event>
    private nonisolated let queue = DispatchSerialQueue(label: "dev.cmux.tests.async-memory-consumer", qos: .utility)
    private let continuation: AsyncStream<Event>.Continuation
    private let queueKey = DispatchSpecificKey<Bool>()
    private var entries: Int
    private let fullEntries: Int

    init(entries: Int) {
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(8))
        self.entries = entries
        fullEntries = entries
        queue.setSpecific(key: queueKey, value: true)
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func updateMemoryLimit(_ limit: MemoryLimit) -> MemoryUsage? {
        record(.update, limit)
    }

    func releaseMemory(downTo limit: MemoryLimit) -> MemoryUsage? {
        entries = min(entries, limit.scale(fullEntries))
        return record(.release, limit)
    }

    private func record(_ call: Event.Call, _ limit: MemoryLimit) -> MemoryUsage? {
        let onQueue = DispatchQueue.getSpecific(key: queueKey) == true
        continuation.yield(Event(call: call, limit: limit, onActorQueue: onQueue))
        return MemoryUsage(footprintBytes: entries * 1024, entries: entries)
    }
}

/// A consumer that keeps its state in a `Mutex`, as the control and environment caches do.
nonisolated final class MutexConsumer: AsyncMemoryConsumer {
    nonisolated enum Call: Equatable, Sendable {
        case update(MemoryLimit)
        case release(MemoryLimit)
    }

    private nonisolated struct State {
        var calls: [Call] = []
        var entries: Int
    }

    private let state: Mutex<State>
    private let fullEntries: Int

    init(entries: Int) {
        state = Mutex(State(entries: entries))
        fullEntries = entries
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    func updateMemoryLimit(_ limit: MemoryLimit) async -> MemoryUsage? {
        state.withLock { state in
            state.calls.append(.update(limit))
            return MemoryUsage(footprintBytes: state.entries * 1024, entries: state.entries)
        }
    }

    func releaseMemory(downTo limit: MemoryLimit) async -> MemoryUsage? {
        let full = fullEntries
        return state.withLock { state in
            state.calls.append(.release(limit))
            state.entries = min(state.entries, limit.scale(full))
            return MemoryUsage(footprintBytes: state.entries * 1024, entries: state.entries)
        }
    }
}

/// An actor whose first update waits inside the call until the test opens it.
private actor GatedConsumer: AsyncMemoryConsumer {
    nonisolated let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private var gate: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var calls: [MutexConsumer.Call] = []

    init() {
        (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func updateMemoryLimit(_ limit: MemoryLimit) async -> MemoryUsage? {
        calls.append(.update(limit))
        enteredContinuation.yield()
        if !isOpen { await withCheckedContinuation { gate = $0 } }
        return MemoryUsage(footprintBytes: 1024, entries: 1)
    }

    func releaseMemory(downTo limit: MemoryLimit) async -> MemoryUsage? {
        calls.append(.release(limit))
        return MemoryUsage(footprintBytes: 0, entries: 0)
    }

    /// Lets the waiting call (and every later one) return.
    func open() {
        isOpen = true
        gate?.resume()
        gate = nil
    }
}

/// Holds the only reference to an async registration so another thread can release it.
nonisolated final class AsyncRegistrationBox: Sendable {
    private let registration: Mutex<AsyncMemoryConsumerRegistration?>
    let entry: MemoryConsumerEntry

    @MainActor init(_ registration: AsyncMemoryConsumerRegistration) {
        entry = registration.entry
        self.registration = Mutex(registration)
    }

    func release() {
        registration.withLock { $0 = nil }
    }
}

/// A hop that holds each delivery until the test runs it, and counts them.
nonisolated final class HopRecorder: Sendable {
    private let deliveries = Mutex<[@Sendable () async -> Void]>([])

    var hop: AsyncMemoryConsumerHop {
        AsyncMemoryConsumerHop { delivery in self.deliveries.withLock { $0.append(delivery) } }
    }

    /// How many deliveries wait to run.
    var pending: Int {
        deliveries.withLock { $0.count }
    }

    /// Runs the waiting deliveries, in the order they were posted.
    func runAll() async {
        let waiting = deliveries.withLock { deliveries in
            let waiting = deliveries
            deliveries = []
            return waiting
        }
        for delivery in waiting { await delivery() }
    }
}
