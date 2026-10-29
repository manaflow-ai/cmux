@testable import CmuxNextDaemon
import Foundation
import Testing

/// A connection's events reach more than one consumer: the store keeps the route's
/// sink (``DaemonConnection/consumeEvents(_:)``), and every other consumer subscribes
/// (``DaemonConnection/subscribe(filter:limit:)``) with a bounded inbox of its own. The reader only
/// appends to an inbox, so a subscriber that stops reading delays no other one and resyncs alone.
///
/// The connections here are never started: the tests emit on the route as the reader would.
@Suite(.timeLimit(.minutes(1))) struct EventFanOutTests {
    private static let count = 10_000

    /// Event `index` (1-based): a title of surface 1, 2 or 3 in turn.
    private static func envelope(_ index: Int) -> DaemonEventEnvelope {
        DaemonEventEnvelope(sequence: UInt64(index),
                            event: .titleChanged(surface: SurfaceID(rawValue: UInt64(index % 3 + 1)), title: "t\(index)"))
    }

    private static func surface(_ event: DaemonEvent) -> UInt64? {
        if case .titleChanged(let surface, _) = event { surface.rawValue } else { nil }
    }

    private static func onSurface(_ wanted: UInt64) -> DaemonEventFilter {
        DaemonEventFilter { surface($0) == wanted }
    }

    private static func connection() -> DaemonConnection {
        DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-fan-out-\(UUID().uuidString).sock"),
                         configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
    }

    /// Everything `subscription` yields until it ends.
    private static func collect(_ subscription: DaemonEventSubscription) -> Task<[DaemonSubscriptionItem], Never> {
        Task {
            var items: [DaemonSubscriptionItem] = []
            for await item in subscription { items.append(item) }
            return items
        }
    }

    private static func sequences(_ items: [DaemonSubscriptionItem]) -> [UInt64] {
        items.compactMap { if case .event(let envelope) = $0 { envelope.sequence } else { nil } }
    }

    /// Matches no subscriber filter here: emitted before the store's consumer starts, it reaches that
    /// consumer when it takes the route's backlog.
    fileprivate static let sentinel = DaemonEventEnvelope(sequence: 0, event: .bell(surface: SurfaceID(rawValue: 0)))

    /// Starts the store's consumer and returns once it took the route (the sentinel reached its sink),
    /// so later events go straight to the sink, not to the backlog that coalesces them.
    private static func consume(_ connection: DaemonConnection, into probe: SinkProbe) async -> Task<Void, any Error> {
        connection.route.emit(sentinel)
        let store = Task { try await connection.consumeEvents { probe.record($0) } }
        var tookBacklog = false
        for await _ in probe.started { tookBacklog = true }
        #expect(tookBacklog, "the store's sink did not take the backlog first")
        return store
    }

    /// Records what the route's sink (the store's path) gets, on the emitting thread, without waiting:
    /// the sentinel ends `started`, every other event goes to `delivered`.
    final class SinkProbe: Sendable {
        let started: AsyncStream<Void>
        let delivered: AsyncStream<UInt64>
        private let startedContinuation: AsyncStream<Void>.Continuation
        private let continuation: AsyncStream<UInt64>.Continuation

        init() {
            (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
            (delivered, continuation) = AsyncStream.makeStream(of: UInt64.self)
        }

        func record(_ envelope: DaemonEventEnvelope) {
            if envelope.sequence == EventFanOutTests.sentinel.sequence {
                startedContinuation.yield()
                startedContinuation.finish()
            } else {
                continuation.yield(envelope.sequence)
            }
        }

        func end() {
            continuation.finish()
        }

        /// Everything the sink got after the sentinel, once ``end()`` ran.
        func all() async -> [UInt64] {
            var sequences: [UInt64] = []
            for await sequence in delivered { sequences.append(sequence) }
            return sequences
        }
    }

    @Test func theStoreAndTwoFilteredSubscribersEachGetEveryMatchingEventInOrder() async throws {
        let connection = Self.connection()
        let probe = SinkProbe()
        let store = await Self.consume(connection, into: probe)
        let first = connection.subscribe(filter: Self.onSurface(1), limit: Self.count)
        let second = connection.subscribe(filter: Self.onSurface(2), limit: Self.count)
        let firstItems = Self.collect(first)
        let secondItems = Self.collect(second)
        // The reader emits from a thread of its own, as the transport's does.
        let (emitted, done) = AsyncStream.makeStream(of: Void.self)
        let reader = Thread {
            for index in 1...Self.count { connection.route.emit(Self.envelope(index)) }
            done.finish()
        }
        reader.name = "fan-out reader"
        reader.qualityOfService = .userInitiated
        reader.start()
        for await _ in emitted {}
        // The connection ends after the reader: what the stream and each inbox hold still reach
        // their consumers.
        await connection.close()
        try await store.value
        probe.end()
        let all = (1...Self.count).map { Self.envelope($0) }
        let sunk = await probe.all()
        #expect(sunk == all.map(\.sequence), "the store's sink missed or reordered events")
        let wantedFirst = all.filter { Self.surface($0.event) == 1 }.map(\.sequence)
        let wantedSecond = all.filter { Self.surface($0.event) == 2 }.map(\.sequence)
        let gotFirst = await firstItems.value
        let gotSecond = await secondItems.value
        #expect(!wantedFirst.isEmpty && !wantedSecond.isEmpty)
        #expect(Self.sequences(gotFirst) == wantedFirst)
        #expect(Self.sequences(gotSecond) == wantedSecond)
        #expect(!gotFirst.contains(.resync) && !gotSecond.contains(.resync), "a subscriber within its limit resynced")
        #expect(connection.route.subscriberCount == 0, "the close left a subscriber on the route")
    }

    @Test func aStoppedSubscriberDelaysNoOtherAndResyncsOnce() async throws {
        let connection = Self.connection()
        let probe = SinkProbe()
        let store = await Self.consume(connection, into: probe)
        let stopped = connection.subscribe(limit: 8)
        let live = connection.subscribe(filter: Self.onSurface(3), limit: Self.count)
        let liveItems = Self.collect(live)
        // Emitted on this task: a subscriber that made the reader wait would hang it here.
        for index in 1...Self.count { connection.route.emit(Self.envelope(index)) }
        #expect(stopped.inbox.held <= 8, "the stopped subscriber holds more than its limit")
        #expect(stopped.resyncCount == 1, "one resync however far the subscriber fell behind")
        await connection.close()
        try await store.value
        probe.end()
        let sunk = await probe.all()
        #expect(sunk.count == Self.count, "the stopped subscriber cost the store events")
        let wanted = (1...Self.count).map { Self.envelope($0) }.filter { Self.surface($0.event) == 3 }.map(\.sequence)
        let got = await liveItems.value
        #expect(Self.sequences(got) == wanted, "the stopped subscriber cost another subscriber events")
        #expect(!got.contains(.resync) && live.resyncCount == 0, "the stopped subscriber's overflow resynced another subscriber")
        // The stopped one reads now: the resync first, then the events after its last overflow, in order.
        var items: [DaemonSubscriptionItem] = []
        for await item in stopped { items.append(item) }
        #expect(items.first == .resync)
        #expect(items.dropFirst().allSatisfy { $0 != .resync })
        let after = Self.sequences(items)
        #expect(after == after.sorted() && after.last == UInt64(Self.count) && after.count <= 8)
    }

    /// The store keeps its own bounded inbox and its frame requests while a subscriber is full.
    @MainActor @Test func theStoreKeepsItsSubscriberWhileAnotherIsFull() async throws {
        let connection = Self.connection()
        let stopped = connection.subscribe(limit: 4)
        let store = DaemonStore()
        let frames = FrameProbe()
        var requested = frames.requests.makeAsyncIterator()
        connection.route.emit(DaemonEventEnvelope(sequence: 1, event: .titleChanged(surface: SurfaceID(rawValue: 1), title: "t1")))
        async let ran: Void = store.run(connection: connection, scheduler: frames)
        _ = await requested.next()
        // Distinct surfaces: the store's inbox coalesces none of them.
        for index in 2...100 {
            connection.route.emit(DaemonEventEnvelope(sequence: UInt64(index),
                                                      event: .titleChanged(surface: SurfaceID(rawValue: UInt64(index)), title: "t\(index)")))
        }
        #expect(store.driver?.inbox.bufferedCount == 100)
        #expect(stopped.resyncCount == 1)
        await connection.close()
        await ran
    }

    final class FrameProbe: FrameBatchScheduler {
        let requests: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            (requests, continuation) = AsyncStream.makeStream(of: Void.self)
        }

        /// Records the request and never runs the drain.
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
            continuation.yield()
        }
    }

    @Test func aSubscriptionEndsWithTheConnectionItsTaskOrItsLastReference() async {
        let connection = Self.connection()
        // Waiting in next() when the connection closes: it ends.
        let waiting = Self.collect(connection.subscribe())
        // A cancelled consumer's subscription leaves the route.
        let cancelled = Self.collect(connection.subscribe())
        cancelled.cancel()
        let cancelledItems = await cancelled.value
        #expect(cancelledItems.isEmpty)
        // A dropped subscription leaves the route at once.
        do { _ = connection.subscribe() }
        #expect(connection.route.subscriberCount == 1, "a cancelled or dropped subscription stayed on the route")
        await connection.close()
        let waitingItems = await waiting.value
        #expect(waitingItems.isEmpty)
        // One taken after the close has already ended.
        var late = connection.subscribe().makeAsyncIterator()
        let lateItem = await late.next()
        #expect(lateItem == nil)
        #expect(connection.route.subscriberCount == 0)
    }

    /// A cancelled consumer ends even when its inbox never empties, and leaves the route.
    @Test func aCancelledConsumerEndsWhileMatchingEventsKeepComing() async {
        let connection = Self.connection()
        let subscription = connection.subscribe(limit: 16)
        for index in 1...8 { connection.route.emit(Self.envelope(index)) }
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let consumer = Task {
            for await _ in gate {}
            var read = 0
            // The reader emits one more matching event per read: the inbox is never empty.
            for await _ in subscription {
                read += 1
                if read == Self.count { break }
                connection.route.emit(Self.envelope(8 + read))
            }
            return read
        }
        consumer.cancel()
        open.finish()
        let read = await consumer.value
        #expect(read == 0, "a cancelled consumer kept taking events")
        #expect(connection.route.subscriberCount == 0, "a cancelled consumer's subscription stayed on the route")
        await connection.close()
    }

    /// A connection that serves requests only buffers nothing and needs no draining task.
    @Test func aDiscardingConnectionBuffersNothingAndStillServesItsSubscribers() async {
        let connection = Self.connection()
        connection.discardEvents()
        let subscriber = Self.collect(connection.subscribe(filter: Self.onSurface(1), limit: Self.count))
        for index in 1...Self.count { connection.route.emit(Self.envelope(index)) }
        #expect(connection.route.streamBacklog == 0, "the discarded stream buffered events")
        await connection.close()
        let wanted = (1...Self.count).map { Self.envelope($0) }.filter { Self.surface($0.event) == 1 }.map(\.sequence)
        let got = await subscriber.value
        #expect(Self.sequences(got) == wanted)
    }

    #if DEBUG
    /// `events` has one consumer: a second iteration would get part of the events, so it traps.
    @Test func aSecondIterationOfEventsTrapsInDebug() async {
        await #expect(processExitsWith: .failure) {
            let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/cmux-fan-out-trap.sock"))
            _ = connection.events.makeAsyncIterator()
            _ = connection.events.makeAsyncIterator()
        }
    }
    #endif
}
