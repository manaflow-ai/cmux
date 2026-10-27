import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A terminal stream on the shared connection (p05-ipc-099): ``TerminalEventQueue`` with
/// ``TerminalEventQueue/Backpressure/dropAndResync(onResync:)`` never parks the reader thread. Over its
/// high water it drops the output a READY supersedes, asks once for that READY and drops such output until
/// it arrives; a byte attach ends with `closed(.overflow)` instead. Nothing here waits on time: the reader
/// thread reports when its pushes returned.
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

    /// Counts the resync hook's calls.
    private final class ResyncCounter: Sendable {
        private let count = Mutex(0)
        var calls: Int { count.withLock { $0 } }
        func hit() { count.withLock { $0 += 1 } }
    }

    private static func chunk(_ byte: UInt8, count: Int = 5) -> TerminalChannelEvent {
        .output(Data(repeating: byte, count: count), colors: nil)
    }

    private static func ready(generation: UInt64) -> TerminalChannelEvent {
        .snapshot(TerminalSnapshotFrame(phase: .ready, generation: generation, offset: 0, version: 1, data: Data([1])))
    }

    /// A stream queue that overflows above 10 bytes; `mergeLimit` 1 keeps every 5-byte chunk apart.
    private static func streamQueue(_ counter: ResyncCounter) -> TerminalEventQueue {
        TerminalEventQueue(highWater: 10, lowWater: 4, mergeLimit: 1,
                           backpressure: .dropAndResync(onResync: { counter.hit() }), recorder: nil)
    }

    @Test func aStoppedConsumerNeverParksTheReaderAndResyncsOnce() async {
        let counter = ResyncCounter()
        let queue = Self.streamQueue(counter)
        queue.push(Self.ready(generation: 1))
        queue.arm()

        // 30 bytes with nobody draining: the reader returns from every push.
        let reader = Reader(pushing: (1...6).map { (queue, Self.chunk(UInt8($0))) })
        await reader.waitUntilReturned()
        #expect(counter.calls == 1)
        #expect(queue.overflowCount == 1)
        #expect(queue.isResyncing)
        #expect(queue.bufferedOutputBytes == 0)

        // A scroll state is kept; output before the requested READY is dropped; the READY ends the resync.
        queue.push(.scrollChanged(offset: 3, atBottom: false))
        queue.push(Self.chunk(7))
        queue.push(Self.ready(generation: 2))
        queue.push(Self.chunk(8))
        #expect(!queue.isResyncing)
        #expect(counter.calls == 1)

        #expect(await queue.next() == .scrollChanged(offset: 3, atBottom: false))
        #expect(await queue.next() == Self.ready(generation: 2))
        #expect(await queue.next() == Self.chunk(8))
        // The old READY, chunks 1-2 (queued), 3 (the overflow), 4-6 and 7 (while resyncing).
        #expect(queue.droppedEventCount == 8)
    }

    /// One reader serves every stream of the connection: a stopped consumer on A holds no event for B.
    @Test func aStoppedConsumerOnOneStreamDoesNotDelayAnother() async {
        let counter = ResyncCounter()
        let streamA = Self.streamQueue(counter)
        let streamB = Self.streamQueue(ResyncCounter())
        streamA.push(Self.ready(generation: 1))
        streamA.arm()
        streamB.arm()

        let flood = (1...20).map { (streamA, Self.chunk(UInt8($0))) }
        let reader = Reader(pushing: flood + [(streamB, Self.chunk(42))])
        #expect(await streamB.next() == Self.chunk(42))
        await reader.waitUntilReturned()
        #expect(counter.calls == 1)
        #expect(streamB.overflowCount == 0)
    }

    /// A byte attach has no READY to ask for: the overflow ends the stream and the view reattaches.
    @Test func aByteAttachOverflowEndsTheStreamWithoutAResync() async {
        let counter = ResyncCounter()
        let queue = Self.streamQueue(counter)
        queue.arm()

        let reader = Reader(pushing: (1...4).map { (queue, Self.chunk(UInt8($0))) })
        await reader.waitUntilReturned()
        #expect(counter.calls == 0)
        #expect(queue.overflowCount == 1)
        #expect(await queue.next() == .closed(.overflow))
        #expect(await queue.next() == nil)
    }

    /// Before the attach reply the queue is not armed: the handshake's history is never dropped.
    @Test func anUnarmedStreamQueueKeepsTheHandshake() async {
        let counter = ResyncCounter()
        let queue = Self.streamQueue(counter)
        let history = (1...4).map {
            TerminalChannelEvent.snapshot(TerminalSnapshotFrame(phase: .history, generation: 1, offset: 0, version: 1,
                                                                data: Data(repeating: UInt8($0), count: 5)))
        }
        queue.push(Self.ready(generation: 1))
        for event in history { queue.push(event) }
        #expect(queue.bufferedOutputBytes == 20)
        #expect(queue.overflowCount == 0)
        #expect(await queue.next() == Self.ready(generation: 1))
        for event in history { #expect(await queue.next() == event) }
        #expect(counter.calls == 0)
    }

    /// One chunk larger than the high water is admitted into an empty queue: it cannot resync forever.
    @Test func anOversizedChunkIntoAnEmptyQueueIsKept() async {
        let counter = ResyncCounter()
        let queue = Self.streamQueue(counter)
        queue.push(Self.ready(generation: 1))
        queue.arm()
        #expect(await queue.next() == Self.ready(generation: 1))

        queue.push(Self.chunk(1, count: 64))
        #expect(queue.overflowCount == 0)
        #expect(await queue.next() == Self.chunk(1, count: 64))
        #expect(counter.calls == 0)
    }

    /// The echo mark of dropped output is dropped too while the resync waits for its READY.
    @Test func anEchoOfDroppedOutputIsDroppedWhileResyncing() async {
        let counter = ResyncCounter()
        let queue = Self.streamQueue(counter)
        queue.push(Self.ready(generation: 1))
        queue.arm()
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }
        #expect(queue.isResyncing)

        queue.pushWithoutWaiting(.inputEcho(flow: 9))
        queue.push(Self.ready(generation: 2))
        queue.pushWithoutWaiting(.inputEcho(flow: 10))
        #expect(await queue.next() == Self.ready(generation: 2))
        #expect(await queue.next() == .inputEcho(flow: 10))
        #expect(counter.calls == 1)
    }

    /// The per-view connection keeps the parking reader: the default policy never drops.
    @Test func theLegacyPolicyNeverDrops() async {
        let queue = TerminalEventQueue(highWater: 10, lowWater: 4, mergeLimit: 1, recorder: nil)
        for byte in UInt8(1)...3 { queue.push(Self.chunk(byte)) }
        #expect(queue.bufferedOutputBytes == 15)
        #expect(queue.overflowCount == 0)
    }

    /// A shared stream's resync is one fire-and-forget request on the connection; its own connection parks instead.
    @Test func aSharedStreamResyncSendsOneRequestAndItsOwnConnectionParks() throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .terminalAttach, stats: nil)
        try daemon.accept()
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }

        let own = TerminalAttachment.backpressure(for: .ownConnection, transport: transport, surface: { SurfaceID(rawValue: 3) })
        guard case .parkReader = own else { Issue.record("its own connection must park the reader"); return }
        let shared = TerminalAttachment.backpressure(for: .sharedStream, transport: transport, surface: { SurfaceID(rawValue: 3) })
        guard case .dropAndResync(let onResync) = shared else { Issue.record("a shared stream must never park"); return }
        onResync()
        #expect(try daemon.readRequestID() > 0)
    }
}
