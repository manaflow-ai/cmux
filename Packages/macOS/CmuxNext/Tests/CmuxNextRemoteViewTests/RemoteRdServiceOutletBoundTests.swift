import CmuxNextCompat
@testable import CmuxNextRemoteView
import Foundation
import Testing

/// The session service's bodies wait for their consumer under the core's own message bound: each
/// costs its JSON bytes plus 64, and once the consumer holds the bound untaken the outlet is backed
/// up, so the transport stops taking the core's messages until the consumer took half.
/// The stream was unbounded, so a stalled consumer grew it with every body the host
/// sent; no body is ever dropped and the session never ends for it.
@Suite struct RemoteRdServiceOutletBoundTests {
    /// A producer offers 100 MB of bodies as fast as the outlet lets it, to a consumer that takes
    /// nothing until the outlet backs up, then takes only until the outlet says it caught up: the
    /// outlet never holds more than its bound and one body, and every body arrives, in order.
    @Test func aStalledConsumerHoldsAtMostTheBoundAndGetsEveryBody() async throws {
        let bound = 256 << 10
        let bodyBytes = 1 << 10
        let cost = bodyBytes + RemoteRdServiceOutlet.bodyOverhead
        let caughtUp = CatchUps()
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteRdServiceMessages.Item.self)
        let outlet = RemoteRdServiceOutlet(continuation, bound: bound) { caughtUp.note() }
        let messages = RemoteRdServiceMessages(base: stream, outlet: outlet)
        var iterator = messages.makeAsyncIterator()

        var offered: Int64 = 0
        var taken: Int64 = 0
        var backups = 0
        var mostHeld = 0
        var outOfOrder = 0
        let total = Int64((100 << 20) / bodyBytes)
        while offered < total {
            guard outlet.isBackedUp else {
                outlet.offer(.int(offered), bytes: bodyBytes)
                offered += 1
                mostHeld = max(mostHeld, outlet.heldCost)
                continue
            }
            // Backed up: the stalled consumer takes bodies until the outlet says it caught up.
            backups += 1
            let before = caughtUp.count
            while caughtUp.count == before, let body = await iterator.next() {
                if body != .int(taken) { outOfOrder += 1 }
                taken += 1
            }
            #expect(outlet.heldCost <= bound / 2)
            #expect(outlet.resumeIfCaughtUp())
        }
        outlet.finish()
        while let body = await iterator.next() {
            if body != .int(taken) { outOfOrder += 1 }
            taken += 1
        }

        #expect(taken == total, "every body arrives")
        #expect(outOfOrder == 0, "in order")
        #expect(mostHeld <= bound + cost, "the outlet held \(mostHeld), past \(bound + cost)")
        #expect(backups >= Int(total) * cost / bound - 1, "the outlet backed up at every bound")
    }

    /// An empty body still costs the overhead, so a flood of empty bodies backs the outlet up too.
    @Test func emptyBodiesCountTheirOverhead() {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteRdServiceMessages.Item.self)
        let outlet = RemoteRdServiceOutlet(continuation, bound: 10 * RemoteRdServiceOutlet.bodyOverhead)
        var offered = 0
        while !outlet.isBackedUp, offered <= 10 {
            outlet.offer(.null, bytes: 0)
            offered += 1
        }
        #expect(offered == 10)
        withExtendedLifetime(stream) { outlet.finish() }
    }

    /// A consumer that stops taking (its stream ends) never holds the producer back: the outlet is no
    /// longer backed up, it says so, and later bodies are not counted.
    @Test func aConsumerThatStopsReleasesTheProducer() {
        let caughtUp = CatchUps()
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteRdServiceMessages.Item.self)
        let outlet = RemoteRdServiceOutlet(continuation, bound: 4 * RemoteRdServiceOutlet.bodyOverhead) { caughtUp.note() }
        var offered = 0
        while !outlet.isBackedUp, offered <= 4 {
            outlet.offer(.null, bytes: 0)
            offered += 1
        }
        #expect(outlet.isBackedUp)
        withExtendedLifetime(stream) { outlet.finish() }

        #expect(!outlet.isBackedUp)
        #expect(caughtUp.count == 1)
        let held = outlet.heldCost
        outlet.offer(.null, bytes: 0)
        #expect(outlet.heldCost == held)
    }
}

/// Counts the outlet's caught-up calls.
private nonisolated final class CatchUps: Sendable {
    private let calls = Atomic<Int>(0)

    var count: Int { calls.load(ordering: .sequentiallyConsistent) }

    func note() {
        calls.add(1, ordering: .sequentiallyConsistent)
    }
}
