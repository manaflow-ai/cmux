import CmuxNextCompat
import CmuxNextWakeupsTestSupport
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A terminal stream on the shared connection: ``TerminalEventQueue`` with
/// ``TerminalEventQueue/Backpressure/dropAndResync(_:)`` never parks the reader thread. Over its high
/// water it drops the output a READY supersedes, asks for that READY and drops such output until it
/// arrives; at most one request is out, a throttled one goes out again after the daemon's delay and a
/// failed one ends the stream with `closed(.overflow)`. A byte attach ends with `closed(.overflow)` at
/// once. Nothing here waits on time: the reader thread reports when its pushes returned, and retries
/// sleep on a manual clock.
@Suite(.timeLimit(.minutes(1))) struct TerminalEventQueueTests {
    /// The reader thread of the shared connection: pushes each `(queue, event)` in order, then reports it returned.
    private final class Reader: Sendable {
        private let done: AsyncStream<Void>

        init(pushing pushes: [(TerminalEventQueue, TerminalChannelEvent)]) {
            let (done, finished) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.done = done
            let thread = Thread {
                for (queue, event) in pushes { queue.push(event) }
                finished.yield()
                finished.finish()
            }
            thread.name = "TerminalEventQueueTests reader"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        func waitUntilReturned() async {
            for await _ in done { return }
        }
    }

    /// The resync request: records each call and keeps its completion for the test to answer.
    private final class FakeResync: Sendable {
        private let completions = Mutex<[@Sendable (TerminalEventQueue.ResyncOutcome) -> Void]>([])
        /// The number of requests so far, after each one.
        private let counts: AsyncStream<Int>
        private let counted: AsyncStream<Int>.Continuation

        init() {
            let (counts, counted) = AsyncStream<Int>.makeStream()
            self.counts = counts
            self.counted = counted
        }

        var calls: Int { completions.withLock { $0.count } }

        var request: TerminalEventQueue.ResyncRequest {
            { [self] completion in
                counted.yield(completions.withLock { $0.append(completion); return $0.count })
            }
        }

        /// Returns once `count` requests went out (one waiter at a time).
        func waitForCalls(_ count: Int) async {
            for await seen in counts where seen >= count { return }
        }

        /// Answers the newest request.
        func answer(_ outcome: TerminalEventQueue.ResyncOutcome) {
            completions.withLock { $0.last }?(outcome)
        }
    }

    private static func chunk(_ byte: UInt8, count: Int = 5) -> TerminalChannelEvent {
        .output(Data(repeating: byte, count: count), colors: nil)
    }

    private static func ready(generation: UInt64) -> TerminalChannelEvent {
        .snapshot(TerminalSnapshotFrame(phase: .ready, generation: generation, offset: 0, version: 1, data: Data([1])))
    }

    private static func history(generation: UInt64, _ byte: UInt8) -> TerminalChannelEvent {
        .snapshot(TerminalSnapshotFrame(phase: .history, generation: generation, offset: 0, version: 1,
                                        data: Data(repeating: byte, count: 5)))
    }

    /// A stream queue that overflows above 10 bytes; `mergeLimit` 1 keeps every 5-byte chunk apart.
    private static func streamQueue(_ resync: FakeResync) -> TerminalEventQueue {
        TerminalEventQueue(highWater: 10, lowWater: 4, mergeLimit: 1,
                           backpressure: .dropAndResync(resync.request), recorder: nil)
    }

    /// An armed stream queue whose consumer took the attach READY.
    private static func attachedStreamQueue(_ resync: FakeResync) async -> TerminalEventQueue {
        let queue = streamQueue(resync)
        queue.push(ready(generation: 1))
        queue.arm()
        #expect(await queue.next() == ready(generation: 1))
        return queue
    }

    @Test func aStoppedConsumerNeverParksTheReaderAndResyncsOnce() async {
        let resync = FakeResync()
        let queue = await Self.attachedStreamQueue(resync)

        // 30 bytes with nobody draining: the reader returns from every push.
        let reader = Reader(pushing: (1...6).map { (queue, Self.chunk(UInt8($0))) })
        await reader.waitUntilReturned()
        #expect(resync.calls == 1)
        #expect(queue.overflowCount == 1)
        #expect(queue.resyncPhase == .awaitingReady)
        #expect(queue.bufferedOutputBytes == 0)

        // A scroll state is kept; output before the requested READY is dropped; the READY ends the resync.
        queue.push(.scrollChanged(offset: 3, atBottom: false))
        queue.push(Self.chunk(7))
        queue.push(Self.ready(generation: 2))
        queue.push(Self.chunk(8))
        #expect(queue.resyncPhase == .idle)
        #expect(resync.calls == 1)

        #expect(await queue.next() == .scrollChanged(offset: 3, atBottom: false))
        #expect(await queue.next() == Self.ready(generation: 2))
        #expect(await queue.next() == Self.chunk(8))
        // Chunks 1-2 (queued), 3 (the overflow), 4-6 and 7 (while resyncing).
        #expect(queue.droppedEventCount == 7)
    }

    /// One reader serves every stream of the connection: a stopped consumer on A holds no event for B.
    @Test func aStoppedConsumerOnOneStreamDoesNotDelayAnother() async {
        let resync = FakeResync()
        let streamA = await Self.attachedStreamQueue(resync)
        let streamB = Self.streamQueue(FakeResync())
        streamB.arm()

        let flood = (1...20).map { (streamA, Self.chunk(UInt8($0))) }
        let reader = Reader(pushing: flood + [(streamB, Self.chunk(42))])
        #expect(await streamB.next() == Self.chunk(42))
        await reader.waitUntilReturned()
        #expect(resync.calls == 1)
        #expect(streamB.overflowCount == 0)
    }

    /// The READY a resync asked for, and its history, never count against the bound: with the consumer
    /// stopped, a history larger than the high water and later output settle on the one request.
    @Test func aResyncReadyWithLargeHistorySettlesOnOneRequest() async {
        let resync = FakeResync()
        let queue = await Self.attachedStreamQueue(resync)
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }
        #expect(resync.calls == 1)

        let history = (UInt8(1)...4).map { Self.history(generation: 2, $0) }
        queue.push(Self.ready(generation: 2))
        for frame in history { queue.push(frame) }
        queue.push(Self.chunk(9))
        #expect(queue.bufferedOutputBytes == 25)
        #expect(queue.overflowCount == 1)
        #expect(queue.resyncPhase == .idle)
        #expect(resync.calls == 1)

        #expect(await queue.next() == Self.ready(generation: 2))
        for frame in history { #expect(await queue.next() == frame) }
        #expect(await queue.next() == Self.chunk(9))
        #expect(resync.calls == 1)
    }

    /// While the requested READY waits for a stopped consumer, an output flood sends no second request:
    /// the queue keeps that READY and its history, drops the output after it, and asks again only once
    /// the consumer takes the READY.
    @Test func anOverflowBehindAnUntakenReadyAsksAgainOnlyWhenTheConsumerTakesIt() async {
        let resync = FakeResync()
        let queue = await Self.attachedStreamQueue(resync)
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }
        #expect(resync.calls == 1)

        let history = (UInt8(1)...4).map { Self.history(generation: 2, $0) }
        queue.push(Self.ready(generation: 2))
        for frame in history { queue.push(frame) }
        let reader = Reader(pushing: (10...30).map { (queue, Self.chunk(UInt8($0))) })
        await reader.waitUntilReturned()
        queue.pushWithoutWaiting(.inputEcho(flow: 5))
        queue.push(.scrollChanged(offset: 4, atBottom: true))
        #expect(queue.resyncPhase == .deferred)
        #expect(queue.overflowCount == 2)
        #expect(resync.calls == 1)

        #expect(await queue.next() == Self.ready(generation: 2))
        #expect(resync.calls == 2)
        #expect(queue.resyncPhase == .awaitingReady)
        for frame in history { #expect(await queue.next() == frame) }
        #expect(await queue.next() == .scrollChanged(offset: 4, atBottom: true))

        queue.push(Self.ready(generation: 3))
        #expect(await queue.next() == Self.ready(generation: 3))
        #expect(resync.calls == 2)
    }

    /// A throttled request goes out again after the daemon's delay, once; a throttled answer that comes
    /// after its READY schedules nothing.
    @Test func aThrottledResyncIsSentAgainAfterTheDaemonsDelay() async throws {
        let resync = FakeResync()
        let clock = ManualClock()
        let queue = TerminalEventQueue(highWater: 10, lowWater: 4, mergeLimit: 1,
                                       backpressure: .dropAndResync(resync.request), clock: clock, recorder: nil)
        queue.push(Self.ready(generation: 1))
        queue.arm()
        #expect(await queue.next() == Self.ready(generation: 1))
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }

        resync.answer(.throttled(retryAfter: .milliseconds(120)))
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline == ManualClock.Instant(offset: .milliseconds(120)))
        #expect(resync.calls == 1)
        clock.advance(by: .milliseconds(120))
        await resync.waitForCalls(2)
        #expect(queue.resyncRequestCount == 2)

        queue.push(Self.ready(generation: 2))
        resync.answer(.throttled(retryAfter: .milliseconds(120)))
        #expect(clock.sleeperCount == 0)
        #expect(await queue.next() == Self.ready(generation: 2))
        #expect(resync.calls == 2)
    }

    /// A request that fails gets no READY: the stream ends with `closed(.overflow)` and the view reattaches.
    @Test func aFailedResyncEndsTheStreamWithOverflow() async {
        let resync = FakeResync()
        let queue = await Self.attachedStreamQueue(resync)
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }
        resync.answer(.failed)
        #expect(await queue.next() == .closed(.overflow))
        #expect(await queue.next() == nil)
    }

    /// A byte attach has no READY to ask for: the overflow ends the stream and the view reattaches.
    @Test func aByteAttachOverflowEndsTheStreamWithoutAResync() async {
        let resync = FakeResync()
        let queue = Self.streamQueue(resync)
        queue.arm()

        let reader = Reader(pushing: (1...4).map { (queue, Self.chunk(UInt8($0))) })
        await reader.waitUntilReturned()
        #expect(resync.calls == 0)
        #expect(queue.overflowCount == 1)
        #expect(await queue.next() == .closed(.overflow))
        #expect(await queue.next() == nil)
    }

    /// Before the attach reply the queue is not armed: the handshake's history is never dropped.
    @Test func anUnarmedStreamQueueKeepsTheHandshake() async {
        let resync = FakeResync()
        let queue = Self.streamQueue(resync)
        let history = (UInt8(1)...4).map { Self.history(generation: 1, $0) }
        queue.push(Self.ready(generation: 1))
        for event in history { queue.push(event) }
        #expect(queue.bufferedOutputBytes == 20)
        #expect(queue.overflowCount == 0)
        #expect(await queue.next() == Self.ready(generation: 1))
        for event in history { #expect(await queue.next() == event) }
        #expect(resync.calls == 0)
    }

    /// One chunk larger than the high water is admitted into an empty queue: it cannot resync forever.
    @Test func anOversizedChunkIntoAnEmptyQueueIsKept() async {
        let resync = FakeResync()
        let queue = await Self.attachedStreamQueue(resync)

        queue.push(Self.chunk(1, count: 64))
        #expect(queue.overflowCount == 0)
        #expect(await queue.next() == Self.chunk(1, count: 64))
        #expect(resync.calls == 0)
    }

    /// The echo mark of dropped output is dropped too while the resync waits for its READY.
    @Test func anEchoOfDroppedOutputIsDroppedWhileResyncing() async {
        let resync = FakeResync()
        let queue = await Self.attachedStreamQueue(resync)
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }
        #expect(queue.resyncPhase == .awaitingReady)

        queue.pushWithoutWaiting(.inputEcho(flow: 9))
        queue.push(Self.ready(generation: 2))
        queue.pushWithoutWaiting(.inputEcho(flow: 10))
        #expect(await queue.next() == Self.ready(generation: 2))
        #expect(await queue.next() == .inputEcho(flow: 10))
        #expect(resync.calls == 1)
    }

    /// An output-resume marker survives the READY that ends a resync: a dropped marker is never resumed,
    /// and live output would stay held off the view's lane.
    @Test func anOutputResumeMarkerSurvivesTheResyncReady() async {
        let resync = FakeResync()
        let queue = await Self.attachedStreamQueue(resync)
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }
        #expect(queue.resyncPhase == .awaitingReady)

        let marker = TerminalOutputMarker(sequence: 1) { _ in }
        queue.pushWithoutWaiting(.outputResume(marker))
        queue.push(Self.ready(generation: 2))
        #expect(await queue.next() == .outputResume(marker))
        #expect(await queue.next() == Self.ready(generation: 2))
        #expect(resync.calls == 1)
    }

    /// The per-view connection keeps the parking reader: the default policy never drops.
    @Test func theLegacyPolicyNeverDrops() async {
        let queue = TerminalEventQueue(highWater: 10, lowWater: 4, mergeLimit: 1, recorder: nil)
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }
        #expect(queue.bufferedOutputBytes == 15)
        #expect(queue.overflowCount == 0)
    }

    @Test func itsOwnConnectionParksTheReader() throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .terminalAttach, stats: nil)
        defer { transport.close() }
        let own = TerminalAttachment.backpressure(for: .ownConnection, transport: transport, surface: { SurfaceID(rawValue: 3) })
        guard case .parkReader = own else { Issue.record("its own connection must park the reader"); return }
    }

    /// A shared stream's queue on a transport to a fake daemon, armed, its attach READY taken.
    private static func sharedStreamQueue(
        _ daemon: ReplyEventOrderTests.FakeDaemon, clock: ManualClock
    ) async throws -> (TerminalEventQueue, LineTransport) {
        let transport = try LineTransport(path: daemon.path, role: .terminalAttach, stats: nil)
        try daemon.accept()
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        let backpressure = TerminalAttachment.backpressure(for: .sharedStream(stream: 7), transport: transport,
                                                           surface: { SurfaceID(rawValue: 3) })
        let queue = TerminalEventQueue(highWater: 10, lowWater: 4, mergeLimit: 1, backpressure: backpressure,
                                       clock: clock, recorder: nil)
        queue.push(ready(generation: 1))
        queue.arm()
        #expect(await queue.next() == ready(generation: 1))
        return (queue, transport)
    }

    /// Reads the resync's `snapshot-request` and checks it names the overflowed stream; returns its id.
    private static func readResyncRequest(_ daemon: ReplyEventOrderTests.FakeDaemon) throws -> UInt64 {
        let request = try daemon.readRequest()
        #expect(request["cmd"] as? String == "snapshot-request")
        #expect((request["surface"] as? NSNumber)?.uint64Value == 3)
        #expect((request["stream"] as? NSNumber)?.uint16Value == 7)
        #expect(request["reason"] as? String == "gap")
        return try #require((request["id"] as? NSNumber)?.uint64Value)
    }

    /// The daemon throttles the request (the view got a snapshot less than 500 ms ago): the queue asks
    /// again after `retry_after_ms`, on the same stream, and the READY reaches the view.
    @Test func aSharedStreamResyncRetriesAThrottledReply() async throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let clock = ManualClock()
        let (queue, transport) = try await Self.sharedStreamQueue(daemon, clock: clock)
        defer { transport.close() }
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }

        let first = try Self.readResyncRequest(daemon)
        daemon.write([#"{"id":\#(first),"ok":true,"data":{"status":"snapshot_throttled","surface":3,"retry_after_ms":120}}"#])
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline == ManualClock.Instant(offset: .milliseconds(120)))
        clock.advance(by: .milliseconds(120))

        let second = try Self.readResyncRequest(daemon)
        daemon.write([#"{"id":\#(second),"ok":true,"data":{"status":"accepted","surface":3}}"#])
        queue.push(Self.ready(generation: 2))
        #expect(await queue.next() == Self.ready(generation: 2))
        #expect(queue.resyncRequestCount == 2)
    }

    /// The daemon refuses the request (`ok:false`): no READY will come, so the stream ends with
    /// `closed(.overflow)` and the attach machine reattaches.
    @Test func aSharedStreamResyncThatIsRefusedEndsWithOverflow() async throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let (queue, transport) = try await Self.sharedStreamQueue(daemon, clock: ManualClock())
        defer { transport.close() }
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }

        let id = try Self.readResyncRequest(daemon)
        daemon.write([#"{"id":\#(id),"ok":false,"error":"not_attached"}"#])
        #expect(await queue.next() == .closed(.overflow))
        #expect(await queue.next() == nil)
    }
}
