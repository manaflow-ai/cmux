@testable import CmuxNextRemoteView
import Foundation
import Testing

/// The session service's bodies wait for their consumer under the core's own message bound: each
/// costs its JSON bytes plus 64, and a consumer that holds the bound untaken refuses the next body,
/// which ends the session as a host that floods the core does (p07-memory-098). The stream was
/// unbounded, so a stalled consumer grew it with every body the host sent.
@Suite struct RemoteRdServiceOutletBoundTests {
    /// A host sends 100 MB of bodies to a consumer that takes nothing until the outlet refuses one,
    /// then takes them all, over and over: the outlet never holds more than its bound, and every body
    /// it accepted arrives, in order.
    @Test func aStalledConsumerHoldsAtMostTheBoundAndGetsEveryAcceptedBody() async throws {
        let bound = 256 << 10
        let bodyBytes = 1 << 10
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteRdServiceMessages.Item.self)
        let outlet = RemoteRdServiceOutlet(continuation, bound: bound)
        let messages = RemoteRdServiceMessages(base: stream, outlet: outlet)
        var iterator = messages.makeAsyncIterator()

        var offered: Int64 = 0
        var taken: Int64 = 0
        var refusals = 0
        var mostHeld = 0
        var outOfOrder = 0
        let total = Int64((100 << 20) / bodyBytes)
        while offered < total {
            if outlet.offer(.int(offered), bytes: bodyBytes) {
                offered += 1
                mostHeld = max(mostHeld, outlet.heldCost)
                continue
            }
            // Refused at the bound: the stalled consumer takes everything it holds.
            refusals += 1
            while taken < offered, let body = await iterator.next() {
                if body != .int(taken) { outOfOrder += 1 }
                taken += 1
            }
            #expect(outlet.heldCost == 0)
        }
        outlet.finish()
        while let body = await iterator.next() {
            if body != .int(taken) { outOfOrder += 1 }
            taken += 1
        }

        #expect(taken == total, "every accepted body arrives")
        #expect(outOfOrder == 0, "in order")
        #expect(mostHeld <= bound, "the outlet held \(mostHeld), past \(bound)")
        #expect(refusals >= Int(total) * (bodyBytes + RemoteRdServiceOutlet.bodyOverhead) / bound - 1,
                "the consumer stalled at every bound")
    }

    /// An empty body still costs the overhead, so a flood of empty bodies is bounded too.
    @Test func emptyBodiesCountTheirOverhead() {
        let (_, continuation) = AsyncStream.makeStream(of: RemoteRdServiceMessages.Item.self)
        let outlet = RemoteRdServiceOutlet(continuation, bound: 10 * RemoteRdServiceOutlet.bodyOverhead)
        var accepted = 0
        while outlet.offer(.null, bytes: 0) { accepted += 1 }
        #expect(accepted == 10)
        outlet.finish()
    }
}
