import Atomics
import CmuxNextIPC
import Testing

/// ``StreamDemux`` (plans/cmux-next/chrome-parity/p05-ipc.md, task 056): a sink is registered before the
/// open, each sink is bounded, an overflow drops and calls the resync hook once, and the reader never
/// waits for a consumer.
@Suite(.timeLimit(.minutes(1))) struct StreamDemuxTests {
    @Test func aStoppedConsumerOnADoesNotDelayBOrTheControlRepliesAndResyncsOnce() async throws {
        let demux = StreamDemux<Chunk>()
        let resyncsA = ManagedAtomic<Int>(0)
        let resyncsB = ManagedAtomic<Int>(0)
        let streamA: UInt16 = 1
        let streamB: UInt16 = 2
        // Registered before the opens are sent: the first frame of each stream already has a sink.
        let sinkA = try demux.register(streamA) { resyncsA.wrappingIncrement(ordering: .relaxed) }
        let sinkB = try demux.register(streamB) { resyncsB.wrappingIncrement(ordering: .relaxed) }
        // A's consumer never reads (a stopped view). B's consumer reads until B's stream-end.
        let consumerB = Task {
            var seen: [Int] = []
            while let chunk = await sinkB.next() { seen.append(chunk.seq) }
            return seen
        }
        await Task.yield()

        // The reader: 300 frames of 64 KiB output for A (18.75 MiB, over A's 8 MiB bound), each followed
        // by a control reply and a small frame for B. `route` is synchronous, so a reader that waited for
        // A's consumer would never get here.
        var controlReplies: [Int] = []
        let frames = 300
        var routesA: [StreamDemux<Chunk>.Route] = []
        for seq in 0 ..< frames {
            routesA.append(demux.route(Chunk(seq: seq, bytes: 64 << 10), to: streamA))
            controlReplies.append(seq)
            #expect(demux.route(Chunk(seq: seq, bytes: 100), to: streamB) == .delivered)
        }
        demux.end(streamB)

        #expect(controlReplies == Array(0 ..< frames))
        #expect(await consumerB.value == Array(0 ..< frames))
        #expect(resyncsB.load(ordering: .relaxed) == 0)

        // A held 8 MiB (128 frames), the 129th overflowed: one resync, and every later frame is dropped.
        let fitting = (8 << 20) / (64 << 10)
        #expect(routesA.prefix(fitting).allSatisfy { $0 == .delivered })
        #expect(routesA.dropFirst(fitting).allSatisfy { $0 == .dropped })
        #expect(resyncsA.load(ordering: .relaxed) == 1)
        #expect(sinkA.overflowCount == 1)
        #expect(sinkA.isResyncing)
        #expect(sinkA.queuedItems == 0 && sinkA.queuedBytes == 0)
        #expect(sinkA.droppedItemCount == frames)

        // The snapshot the resync asked for starts a fresh state; A's consumer reads from it on.
        #expect(demux.route(Chunk(seq: 1000, bytes: 4096, fresh: true), to: streamA) == .delivered)
        #expect(demux.route(Chunk(seq: 1001, bytes: 64), to: streamA) == .delivered)
        #expect(!sinkA.isResyncing)
        #expect(await sinkA.next()?.seq == 1000)
        #expect(await sinkA.next()?.seq == 1001)
        #expect(resyncsA.load(ordering: .relaxed) == 1)
    }

    @Test func eachOverflowCallsTheResyncHookOnce() throws {
        let demux = StreamDemux<Chunk>(limits: .init(maxBytes: 100, maxItems: 1000))
        let resyncs = ManagedAtomic<Int>(0)
        let sink = try demux.register(7) { resyncs.wrappingIncrement(ordering: .relaxed) }

        for seq in 0 ..< 3 { #expect(demux.route(Chunk(seq: seq, bytes: 30), to: 7) == .delivered) }
        #expect(sink.queuedBytes == 90)
        #expect(demux.route(Chunk(seq: 3, bytes: 30), to: 7) == .dropped)
        for seq in 4 ..< 50 { #expect(demux.route(Chunk(seq: seq, bytes: 30), to: 7) == .dropped) }
        #expect(resyncs.load(ordering: .relaxed) == 1)
        #expect(sink.droppedItemCount == 50)

        #expect(demux.route(Chunk(seq: 50, bytes: 30, fresh: true), to: 7) == .delivered)
        for seq in 51 ..< 53 { #expect(demux.route(Chunk(seq: seq, bytes: 30), to: 7) == .delivered) }
        #expect(demux.route(Chunk(seq: 53, bytes: 30), to: 7) == .dropped)
        #expect(resyncs.load(ordering: .relaxed) == 2)
        #expect(sink.overflowCount == 2)
    }

    @Test func theItemBoundOverflowsLikeTheByteBound() throws {
        let demux = StreamDemux<Chunk>(limits: .init(maxBytes: 1 << 20, maxItems: 4))
        let resyncs = ManagedAtomic<Int>(0)
        let sink = try demux.register(9) { resyncs.wrappingIncrement(ordering: .relaxed) }
        for seq in 0 ..< 4 { #expect(demux.route(Chunk(seq: seq, bytes: 1), to: 9) == .delivered) }
        #expect(demux.route(Chunk(seq: 4, bytes: 1), to: 9) == .dropped)
        #expect(resyncs.load(ordering: .relaxed) == 1)
        #expect(sink.queuedItems == 0)
    }

    @Test func anItemLargerThanTheBoundIsAdmittedIntoAnEmptyQueue() async throws {
        let demux = StreamDemux<Chunk>(limits: .init(maxBytes: 100, maxItems: 10))
        let resyncs = ManagedAtomic<Int>(0)
        let sink = try demux.register(4) { resyncs.wrappingIncrement(ordering: .relaxed) }
        #expect(demux.route(Chunk(seq: 0, bytes: 500), to: 4) == .delivered)
        #expect(resyncs.load(ordering: .relaxed) == 0)
        #expect(await sink.next()?.seq == 0)
    }

    @Test func aFreshStateThatOverflowsReplacesTheQueueWithoutAResync() async throws {
        let demux = StreamDemux<Chunk>(limits: .init(maxBytes: 100, maxItems: 10))
        let resyncs = ManagedAtomic<Int>(0)
        let sink = try demux.register(5) { resyncs.wrappingIncrement(ordering: .relaxed) }
        for seq in 0 ..< 3 { demux.route(Chunk(seq: seq, bytes: 30), to: 5) }
        #expect(demux.route(Chunk(seq: 3, bytes: 60, fresh: true), to: 5) == .delivered)
        #expect(resyncs.load(ordering: .relaxed) == 0)
        #expect(!sink.isResyncing)
        #expect(sink.queuedItems == 1 && sink.queuedBytes == 60)
        #expect(sink.droppedItemCount == 3)
        #expect(await sink.next()?.seq == 3)
    }

    @Test func itemsComeOutInStreamOrderAcrossInterleavedReads() async throws {
        let demux = StreamDemux<Chunk>()
        let sink = try demux.register(3) {}
        demux.route(Chunk(seq: 1, bytes: 1), to: 3)
        demux.route(Chunk(seq: 2, bytes: 1), to: 3)
        #expect(await sink.next()?.seq == 1)
        demux.route(Chunk(seq: 3, bytes: 1), to: 3)
        #expect(await sink.next()?.seq == 2)
        demux.route(Chunk(seq: 4, bytes: 1), to: 3)
        #expect(await sink.next()?.seq == 3)
        #expect(await sink.next()?.seq == 4)
        #expect(sink.queuedItems == 0 && sink.queuedBytes == 0)
    }

    @Test func aParkedConsumerGetsTheNextItemHandedOver() async throws {
        let demux = StreamDemux<Chunk>()
        let sink = try demux.register(6) {}
        let consumer = Task { await sink.next() }
        await Task.yield()
        #expect(demux.route(Chunk(seq: 42, bytes: 8), to: 6) == .delivered)
        #expect(await consumer.value?.seq == 42)
        #expect(sink.queuedItems == 0)
    }

    @Test func theStreamEndDeliversWhatIsQueuedThenNilAndFreesTheID() async throws {
        let demux = StreamDemux<Chunk>()
        let sink = try demux.register(8) {}
        demux.route(Chunk(seq: 1, bytes: 1), to: 8)
        demux.route(Chunk(seq: 2, bytes: 1), to: 8)
        demux.end(8)
        #expect(await sink.next()?.seq == 1)
        #expect(await sink.next()?.seq == 2)
        #expect(await sink.next() == nil)
        // The id is free again, and the old sink takes nothing more.
        let again = try demux.register(8) {}
        #expect(demux.route(Chunk(seq: 3, bytes: 1), to: 8) == .delivered)
        #expect(await again.next()?.seq == 3)
        #expect(sink.queuedItems == 0)
    }

    @Test func registrationRefusesTheControlStreamAndAnIDStillInUse() throws {
        let demux = StreamDemux<Chunk>()
        #expect(throws: StreamDemuxError.reservedStream) { _ = try demux.register(0) {} }
        _ = try demux.register(11) {}
        #expect(throws: StreamDemuxError.streamInUse(11)) { _ = try demux.register(11) {} }
    }

    @Test func framesForAStreamWithNoSinkAreCountedUntilItsEnd() throws {
        let demux = StreamDemux<Chunk>()
        #expect(demux.route(Chunk(seq: 0, bytes: 1), to: 20) == .unknown)
        #expect(demux.route(Chunk(seq: 1, bytes: 1), to: 20) == .unknown)
        #expect(demux.route(Chunk(seq: 0, bytes: 1), to: 21) == .unknown)
        #expect(demux.unknownItemCount == 3)
        demux.end(20)
        #expect(demux.unknownItemCount == 1)
        // Registering an id forgets what an older use of it left uncounted.
        _ = try demux.register(21) {}
        #expect(demux.unknownItemCount == 0)
    }

    @Test func aCancelledSinkDropsEverythingUntilTheStreamEnd() async throws {
        let demux = StreamDemux<Chunk>()
        let resyncs = ManagedAtomic<Int>(0)
        let sink = try demux.register(12) { resyncs.wrappingIncrement(ordering: .relaxed) }
        demux.route(Chunk(seq: 0, bytes: 1), to: 12)
        sink.cancel()
        #expect(await sink.next() == nil)
        #expect(demux.route(Chunk(seq: 1, bytes: 1), to: 12) == .dropped)
        #expect(sink.droppedItemCount == 2)
        #expect(resyncs.load(ordering: .relaxed) == 0)
        #expect(throws: StreamDemuxError.streamInUse(12)) { _ = try demux.register(12) {} }
        demux.end(12)
        _ = try demux.register(12) {}
    }

    @Test func cancellingTheWaitingTaskEndsItsNextWithNil() async throws {
        let demux = StreamDemux<Chunk>()
        let sink = try demux.register(13) {}
        let waiting = Task { await sink.next() }
        waiting.cancel()
        #expect(await waiting.value == nil)
        // The sink stays open for the next read.
        demux.route(Chunk(seq: 5, bytes: 1), to: 13)
        #expect(await sink.next()?.seq == 5)
    }

    @Test func connectionLossEndsEveryStream() async throws {
        let demux = StreamDemux<Chunk>()
        let first = try demux.register(1) {}
        let second = try demux.register(2) {}
        let waiting = Task { await second.next() }
        await Task.yield()
        demux.route(Chunk(seq: 9, bytes: 1), to: 1)
        demux.route(Chunk(seq: 0, bytes: 1), to: 30)
        demux.endAll()
        #expect(await waiting.value == nil)
        #expect(await first.next()?.seq == 9)
        #expect(await first.next() == nil)
        #expect(demux.unknownItemCount == 0)
        #expect(demux.route(Chunk(seq: 10, bytes: 1), to: 1) == .closed)
        #expect(demux.unknownItemCount == 0)
    }

    @Test func registerAfterConnectionLossThrowsInsteadOfParkingForever() async throws {
        let demux = StreamDemux<Chunk>()
        demux.endAll()
        // A view that registers after the reader's EOF must not get an open sink nothing will end.
        #expect(throws: StreamDemuxError.connectionClosed) { _ = try demux.register(4) {} }
        #expect(demux.route(Chunk(seq: 1, bytes: 1), to: 4) == .closed)
        #expect(demux.unknownItemCount == 0)
        demux.end(4)
        #expect(throws: StreamDemuxError.connectionClosed) { _ = try demux.register(4) {} }
    }
}

/// A routed item of `bytes` payload bytes; `fresh` marks a snapshot.
private nonisolated struct Chunk: StreamSinkItem, Equatable {
    let seq: Int
    let sinkByteCount: Int
    let startsFreshState: Bool

    init(seq: Int, bytes: Int, fresh: Bool = false) {
        self.seq = seq
        sinkByteCount = bytes
        startsFreshState = fresh
    }
}
