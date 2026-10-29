import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The attach reader's backpressure (``TerminalEventQueue``): an armed queue parks the reader thread above its
/// high water and lets it go at its low water, at the end of the stream, or when the consumer drops it. Nothing
/// here waits on time: the reader reports when it blocked and when its pushes returned (the
/// state behind a checked lock and the reader on a semaphore, instead of unchecked condition-guarded fields).
@Suite(.timeLimit(.minutes(1))) struct TerminalEventQueueBackpressureTests {
    /// A dedicated reader thread, as the attach connection's: pushes `events`, then reports that it returned.
    private final class Reader: Sendable {
        private let returnedFlag = Mutex(false)
        private let done: AsyncStream<Void>

        init(_ queue: TerminalEventQueue, pushing events: [TerminalChannelEvent]) {
            let (done, finished) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.done = done
            let thread = Thread { [self] in
                for event in events { queue.push(event) }
                returnedFlag.withLock { $0 = true }
                finished.yield()
                finished.finish()
            }
            thread.name = "TerminalEventQueueBackpressureTests reader"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        /// Whether every push returned.
        var returned: Bool { returnedFlag.withLock { $0 } }

        func waitUntilReturned() async {
            for await _ in done { return }
        }
    }

    private static func chunk(_ byte: UInt8) -> TerminalChannelEvent {
        .output(Data(repeating: byte, count: 5), colors: nil)
    }

    /// A queue that parks above 10 bytes and releases at 4; `mergeLimit` 1 keeps every 5-byte chunk apart.
    private static func armedQueue(onReaderBlocked: @escaping @Sendable () -> Void) -> TerminalEventQueue {
        let queue = TerminalEventQueue(highWater: 10, lowWater: 4, mergeLimit: 1, recorder: nil, onReaderBlocked: onReaderBlocked)
        queue.arm()
        return queue
    }

    @Test func aParkedReaderReadsAgainAtTheLowWater() async {
        let (blocks, blocked) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let queue = Self.armedQueue { blocked.yield() }
        let reader = Reader(queue, pushing: [Self.chunk(1), Self.chunk(2), Self.chunk(3)])
        var blockEvents = blocks.makeAsyncIterator()
        #expect(await blockEvents.next() != nil)
        #expect(queue.bufferedOutputBytes == 15)

        // 10 and then 5 bytes left: above the low water, nothing releases the reader.
        #expect(await queue.next() == Self.chunk(1))
        #expect(!reader.returned)
        #expect(await queue.next() == Self.chunk(2))
        #expect(!reader.returned)
        // 0 bytes left: the reader goes on.
        #expect(await queue.next() == Self.chunk(3))
        await reader.waitUntilReturned()
        #expect(reader.returned)
    }

    /// The reader parks, reads again at the low water, and parks a second time on its next pushes: one release
    /// signal per park, so the second park holds until the consumer drains to the low water again. Bytes queued
    /// without waiting (a history snapshot) while it is parked count toward that low water too.
    @Test func aReleasedReaderParksAgainAndHoldsUntilTheNextLowWater() async {
        let (blocks, blocked) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let queue = Self.armedQueue { blocked.yield() }
        let chunks = (1...6).map { Self.chunk(UInt8($0)) }
        let reader = Reader(queue, pushing: chunks)
        var blockEvents = blocks.makeAsyncIterator()

        // First park on the third chunk; draining to 0 bytes lets it go.
        #expect(await blockEvents.next() != nil)
        #expect(await queue.next() == chunks[0])
        #expect(await queue.next() == chunks[1])
        #expect(await queue.next() == chunks[2])

        // Second park on the sixth chunk: the reader did not return, and only what it pushed after the release is queued.
        #expect(await blockEvents.next() != nil)
        #expect(!reader.returned)
        #expect(queue.bufferedOutputBytes == 15)
        let history = TerminalChannelEvent.snapshot(TerminalSnapshotFrame(phase: .history, generation: 1, offset: 0, version: 1,
                                                                          data: Data(repeating: 9, count: 100)))
        queue.pushWithoutWaiting(history)
        #expect(queue.bufferedOutputBytes == 115)

        // 110, 105, then 100 bytes left: all above the low water, so the second park holds.
        #expect(await queue.next() == chunks[3])
        #expect(!reader.returned)
        #expect(await queue.next() == chunks[4])
        #expect(!reader.returned)
        #expect(await queue.next() == chunks[5])
        #expect(!reader.returned)
        // 0 bytes left: the reader goes on and returns from its last push.
        #expect(await queue.next() == history)
        await reader.waitUntilReturned()
        #expect(reader.returned)
        #expect(queue.bufferedOutputBytes == 0)
    }

    @Test func finishReleasesAParkedReaderAndKeepsWhatIsQueued() async {
        let (blocks, blocked) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let queue = Self.armedQueue { blocked.yield() }
        let reader = Reader(queue, pushing: [Self.chunk(1), Self.chunk(2), Self.chunk(3)])
        var blockEvents = blocks.makeAsyncIterator()
        #expect(await blockEvents.next() != nil)

        queue.finish()
        await reader.waitUntilReturned()
        #expect(await queue.next() == Self.chunk(1))
        #expect(await queue.next() == Self.chunk(2))
        #expect(await queue.next() == Self.chunk(3))
        #expect(await queue.next() == nil)
    }

    @Test func cancelReleasesAParkedReaderAndDropsWhatIsQueued() async {
        let (blocks, blocked) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let queue = Self.armedQueue { blocked.yield() }
        let reader = Reader(queue, pushing: [Self.chunk(1), Self.chunk(2), Self.chunk(3)])
        var blockEvents = blocks.makeAsyncIterator()
        #expect(await blockEvents.next() != nil)

        queue.cancel()
        await reader.waitUntilReturned()
        #expect(queue.bufferedOutputBytes == 0)
        #expect(await queue.next() == nil)
    }

    /// Before the attach reply (a replay, the handshake) the queue is not armed: no push ever waits.
    @Test func anUnarmedQueueNeverParksTheReader() async {
        let queue = TerminalEventQueue(highWater: 10, lowWater: 4, mergeLimit: 1, recorder: nil)
        let reader = Reader(queue, pushing: [Self.chunk(1), Self.chunk(2), Self.chunk(3)])
        await reader.waitUntilReturned()
        #expect(queue.bufferedOutputBytes == 15)
    }

    /// A consumer already waiting takes the pushed event directly: nothing is queued, nothing parks.
    @Test func aWaitingConsumerTakesThePushDirectly() async {
        let queue = Self.armedQueue {}
        async let first = queue.next()
        // The consumer parks before the push or finds the event queued: either way it gets this chunk.
        let reader = Reader(queue, pushing: [Self.chunk(7)])
        #expect(await first == Self.chunk(7))
        await reader.waitUntilReturned()
        #expect(queue.bufferedOutputBytes == 0)
    }
}
