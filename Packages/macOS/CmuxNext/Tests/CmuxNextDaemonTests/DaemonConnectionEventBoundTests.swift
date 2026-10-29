@testable import CmuxNextDaemon
import Foundation
import Testing

/// A ``DaemonConnection``'s event backlog holds at most the route's high water of line bytes its
/// stream consumer has not taken: past it the reader thread waits, so the socket stops draining and
/// the daemon's bounded outbound queue acts, until the consumer takes the backlog.
/// The stream was unbounded, so a consumer that stalled grew it without limit; the backlog's own
/// count bound would collapse it into a resync instead of slowing the daemon.
/// The reader waits only for a live consumer: before the stream is taken and after its consumer
/// stopped, the replies the reader reads on the same connection must still get through.
@Suite(.serialized, .timeLimit(.minutes(2))) struct DaemonConnectionEventBoundTests {
    private nonisolated static func envelope(_ sequence: UInt64) -> DaemonEventEnvelope {
        // A bell: the backlog coalesces titles of one surface, so each emit stays one event.
        DaemonEventEnvelope(sequence: sequence, event: .bell(surface: 1))
    }

    /// The reader thread's part: emit each event, then, past the line, the backpressure wait
    /// (LineTransport calls ``DaemonEventRoute/waitWhileReaderParked()`` after each line).
    private nonisolated static func read(_ route: DaemonEventRoute, events count: Int, lineBytes: Int) {
        for sequence in 1...UInt64(count) {
            route.emit(envelope(sequence), bytes: lineBytes, parksReader: true)
            route.waitWhileReaderParked()
        }
    }

    /// A reader emits 100 MB of event lines to a consumer that takes nothing until the reader waits,
    /// then takes the backlog and reads exactly what it took, over and over, and at last reads freely:
    /// the backlog never holds more than the high water and one event, never collapses, and every
    /// event arrives, in order.
    @Test func aStalledConsumerHoldsAtMostTheHighWaterAndLosesNoEvent() async throws {
        let lineBytes = 1 << 10
        let count = (100 << 20) / lineBytes
        // One notification per park. Only the consumer's take releases the reader, and each cycle below
        // takes once, so the next notification is always a park still in force.
        let (parks, parked) = AsyncStream<Void>.makeStream()
        let route = DaemonEventRoute(highWater: 64 << 10, onReaderParked: { parked.yield() })
        let events = DaemonEventStream(route: route)
        let ceiling = route.highWater + lineBytes
        // Taken before the reader starts: the reader waits only for a taken stream.
        var iterator = events.makeAsyncIterator()

        let reader = Thread {
            Self.read(route, events: count, lineBytes: lineBytes)
            route.finish()
        }
        reader.name = "test.daemon.reader"
        reader.start()

        var parkWaits = parks.makeAsyncIterator()
        var expected: UInt64 = 1
        var outOfOrder = 0
        var mostHeld = 0
        // Stalled: wait for the reader to stop, then take the backlog (the first next) and read what it held.
        for _ in 0..<64 {
            _ = await parkWaits.next()
            #expect(route.isReaderParked)
            let held = route.streamBacklogBytes
            mostHeld = max(mostHeld, held)
            for _ in 0..<(held / lineBytes) {
                let envelope = try #require(try await iterator.next())
                if envelope.sequence != expected { outOfOrder += 1 }
                expected = envelope.sequence + 1
            }
        }
        // Then free reading to the end.
        while let envelope = try await iterator.next() {
            mostHeld = max(mostHeld, route.streamBacklogBytes)
            if envelope.sequence != expected { outOfOrder += 1 }
            expected = envelope.sequence + 1
        }

        #expect(expected == UInt64(count) + 1, "every event arrives")
        #expect(outOfOrder == 0, "in order")
        #expect(mostHeld <= ceiling, "the backlog held \(mostHeld) bytes, past \(ceiling)")
        #expect(route.streamBacklogBytes == 0)
    }

    /// Before its owner takes the stream, the reader never waits, however many event lines come: the
    /// owner sends requests on the connection first (a handoff, a prepare, an identify), and their
    /// replies come on this reader. Once the owner takes the stream, every event is there, in order.
    @Test func aFloodBeforeTheStreamIsTakenStillLetsAReplyThrough() async throws {
        let lineBytes = 1 << 10
        let count = 64
        let (replies, reply) = AsyncStream<Void>.makeStream()
        let route = DaemonEventRoute(highWater: 4 << 10)
        let events = DaemonEventStream(route: route)

        let reader = Thread {
            Self.read(route, events: count, lineBytes: lineBytes)
            // The line after the flood: the reply to the owner's request.
            reply.yield()
        }
        reader.start()

        var replyWaits = replies.makeAsyncIterator()
        _ = await replyWaits.next()
        #expect(!route.isReaderParked)
        #expect(route.streamBacklogBytes == count * lineBytes)

        route.finish()
        var expected: UInt64 = 1
        for try await envelope in events {
            #expect(envelope.sequence == expected)
            expected += 1
        }
        #expect(expected == UInt64(count) + 1, "every event arrives")
    }

    /// A consumer that drops its iterator while the reader waits for it releases the reader, and the
    /// reader never waits for it again: every later line on the connection still gets read.
    @Test func aDroppedConsumerReleasesTheReaderForGood() async throws {
        let (parks, parked) = AsyncStream<Void>.makeStream()
        let (ends, ended) = AsyncStream<Void>.makeStream()
        let route = DaemonEventRoute(highWater: 4 << 10, onReaderParked: { parked.yield() })
        let events = DaemonEventStream(route: route)

        do {
            var iterator = events.makeAsyncIterator()
            let reader = Thread {
                Self.read(route, events: 64, lineBytes: 1 << 10)
                ended.yield()
            }
            reader.start()
            var parkWaits = parks.makeAsyncIterator()
            _ = await parkWaits.next()
            #expect(route.isReaderParked)
            #expect(try await iterator.next()?.sequence == 1)
        }

        var endWaits = ends.makeAsyncIterator()
        _ = await endWaits.next()
        #expect(!route.isReaderParked)
        route.finish()
    }

    /// A consumer whose task is cancelled ends its iteration; the events the reader emits after it are
    /// never taken, so they are not counted and the reader never waits for them.
    @Test func aCancelledConsumerReleasesTheReader() async throws {
        let (parks, parked) = AsyncStream<Void>.makeStream()
        let (ends, ended) = AsyncStream<Void>.makeStream()
        let (starts, started) = AsyncStream<Void>.makeStream()
        // What the consumer waits on after each event; it ends only when its task is cancelled.
        let (holds, hold) = AsyncStream<Void>.makeStream()
        let route = DaemonEventRoute(highWater: 4 << 10, onReaderParked: { parked.yield() })
        let events = DaemonEventStream(route: route)

        // task-owner: the test's consumer; cancelled below while the reader waits for it
        let consumer = Task {
            var iterator = events.makeAsyncIterator()
            started.yield()
            while try await iterator.next() != nil {
                var holding = holds.makeAsyncIterator()
                _ = await holding.next()
            }
        }
        var startWaits = starts.makeAsyncIterator()
        _ = await startWaits.next()
        let reader = Thread {
            Self.read(route, events: 256, lineBytes: 1 << 10)
            ended.yield()
        }
        reader.start()
        var parkWaits = parks.makeAsyncIterator()
        _ = await parkWaits.next()
        #expect(route.isReaderParked)
        consumer.cancel()

        var endWaits = ends.makeAsyncIterator()
        _ = await endWaits.next()
        #expect(!route.isReaderParked)
        route.finish()
        hold.finish()
        _ = try? await consumer.value
    }

    /// A reader waiting for a consumer that stopped taking is released when the connection closes
    /// (``DaemonEventRoute/finish(throwing:)``), so the reader thread ends and closes the socket.
    @Test func closingTheConnectionReleasesAWaitingReader() async throws {
        let (parks, parked) = AsyncStream<Void>.makeStream()
        let (ends, ended) = AsyncStream<Void>.makeStream()
        let route = DaemonEventRoute(highWater: 4 << 10, onReaderParked: { parked.yield() })
        let events = DaemonEventStream(route: route)
        let iterator = events.makeAsyncIterator()

        let reader = Thread {
            Self.read(route, events: 64, lineBytes: 1 << 10)
            ended.yield()
        }
        reader.start()

        var parkWaits = parks.makeAsyncIterator()
        _ = await parkWaits.next()
        #expect(route.isReaderParked)
        route.finish()
        var endWaits = ends.makeAsyncIterator()
        _ = await endWaits.next()
        #expect(!route.isReaderParked)
        withExtendedLifetime(iterator) {}
    }

    /// Events the actor emits (`connected`, `disconnected`) never wait, however full the taken stream is.
    @Test func anEventFromTheActorNeverWaits() {
        let route = DaemonEventRoute(highWater: 1 << 10)
        let events = DaemonEventStream(route: route)
        let iterator = events.makeAsyncIterator()
        for sequence in 1...UInt64(16) {
            route.emit(Self.envelope(sequence), bytes: 1 << 10)
            route.waitWhileReaderParked()
        }
        #expect(route.streamBacklogBytes == 16 << 10)
        #expect(!route.isReaderParked)
        route.finish()
        withExtendedLifetime(iterator) {}
    }
}
