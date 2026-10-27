@testable import CmuxNextDaemon
import Foundation
import Testing

/// A ``DaemonConnection``'s event stream holds at most the route's high water of line bytes its
/// consumer has not taken: past it the reader thread waits, so the socket stops draining and the
/// daemon's bounded outbound queue acts, until the consumer has taken the stream down to the low
/// water (p07-memory-098). The stream was unbounded, so a consumer that stalled grew it without limit.
@Suite(.serialized, .timeLimit(.minutes(2))) struct DaemonConnectionEventBoundTests {
    private nonisolated static func envelope(_ sequence: UInt64) -> DaemonEventEnvelope {
        DaemonEventEnvelope(sequence: sequence, event: .titleChanged(surface: 1, title: "t"))
    }

    /// A reader emits 100 MB of event lines to a consumer that takes nothing until the reader waits,
    /// then takes the stream down to the low water, over and over, and at last reads freely: the
    /// stream never holds more than the high water and one event, and every event arrives, in order.
    @Test func aStalledConsumerHoldsAtMostTheHighWaterAndLosesNoEvent() async throws {
        let lineBytes = 1 << 10
        let count = (100 << 20) / lineBytes
        let (base, continuation) = AsyncThrowingStream.makeStream(of: DaemonEventEnvelope.self)
        let (parks, parked) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let route = DaemonEventRoute(continuation, highWater: 64 << 10, lowWater: 16 << 10, onReaderParked: { parked.yield() })
        let events = DaemonEventStream(base: base, route: route)
        let ceiling = route.highWater + lineBytes

        let reader = Thread {
            for sequence in 1...UInt64(count) {
                route.emit(Self.envelope(sequence), bytes: lineBytes, parksReader: true)
            }
            route.finish()
        }
        reader.name = "test.daemon.reader"
        reader.start()

        var iterator = events.makeAsyncIterator()
        var parkWaits = parks.makeAsyncIterator()
        var expected: UInt64 = 1
        var outOfOrder = 0
        var mostHeld = 0
        // Stalled: wait for the reader to stop, then take the stream down to the low water.
        for _ in 0..<64 {
            _ = await parkWaits.next()
            #expect(route.isReaderParked)
            mostHeld = max(mostHeld, route.streamBacklogBytes)
            while route.streamBacklogBytes > route.lowWater, let envelope = try await iterator.next() {
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
        #expect(mostHeld <= ceiling, "the stream held \(mostHeld) bytes, past \(ceiling)")
        #expect(route.streamBacklogBytes == 0)
    }

    /// A reader waiting for a consumer that never comes is released when the connection closes
    /// (``DaemonEventRoute/finish(throwing:)``), so the reader thread ends and closes the socket.
    @Test func closingTheConnectionReleasesAWaitingReader() async throws {
        let (_, continuation) = AsyncThrowingStream.makeStream(of: DaemonEventEnvelope.self)
        let (parks, parked) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (ends, ended) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let route = DaemonEventRoute(continuation, highWater: 4 << 10, lowWater: 1 << 10, onReaderParked: { parked.yield() })

        let reader = Thread {
            for sequence in 1...UInt64(64) {
                route.emit(Self.envelope(sequence), bytes: 1 << 10, parksReader: true)
            }
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
    }

    /// Events the actor emits (`connected`, `disconnected`) never wait, however full the stream is.
    @Test func anEventFromTheActorNeverWaits() {
        let (_, continuation) = AsyncThrowingStream.makeStream(of: DaemonEventEnvelope.self)
        let route = DaemonEventRoute(continuation, highWater: 1 << 10, lowWater: 0)
        for sequence in 1...UInt64(16) {
            route.emit(Self.envelope(sequence), bytes: 1 << 10)
        }
        #expect(route.streamBacklogBytes == 16 << 10)
        #expect(!route.isReaderParked)
        route.finish()
    }
}
