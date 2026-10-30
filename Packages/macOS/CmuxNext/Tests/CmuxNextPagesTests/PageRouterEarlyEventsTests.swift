import CmuxNextSettings
@testable import CmuxNextPages
import Testing

/// Events a provider sends while its `subscribe` runs (its current state: the icon picker's open
/// session, the activity requests, the update island) wait for the reply that names the
/// subscription, then reach the page once, in order. Once the subscription is answered, an event
/// goes straight to the page (or into the router's hold) in its own turn.
@MainActor
struct PageRouterEarlyEventsTests {
    private final class Sent {
        var envelopes: [JSONValue] = []

        var numbers: [Double] {
            envelopes.flatMap { envelope -> [JSONValue] in
                envelope["t"]?.stringValue == "evs" ? envelope["events"]?.arrayValue ?? [] : [envelope]
            }.compactMap { $0["data"]?["n"]?.doubleValue }
        }
    }

    private func router(_ provider: PageRouterFrozenDeliveryTests.StreamProvider) -> (PageRouter, Sent) {
        let router = PageRouter(descriptor: PageRouterFrozenDeliveryTests.descriptor,
                                routes: [PageRoute(prefix: "cmux.held.", provider: provider)])
        let sent = Sent()
        router.send = { sent.envelopes.append($0) }
        return (router, sent)
    }

    /// Lets the main-actor job the router posts after the reply run (bounded: a lost event fails, never hangs).
    private func settle(until done: () -> Bool) async {
        for _ in 0..<1_000 where !done() { await Task.yield() }
    }

    @Test func aStateSentInsideSubscribeReachesThePageAfterTheReply() async {
        let provider = PageRouterFrozenDeliveryTests.StreamProvider(["cmux.held.state": .latest])
        provider.eventsDuringSubscribe = 2
        let (router, sent) = router(provider)
        let reply = await router.handle(["t": "sub", "id": 1, "stream": "cmux.held.state"])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(sent.envelopes.isEmpty, "the state went out before the reply that names its subscription")
        await settle { !sent.numbers.isEmpty }
        #expect(sent.numbers == [0, 1], "the state the provider sent inside subscribe never reached the page")
        provider.emit("cmux.held.state", 2..<3)
        #expect(sent.numbers == [0, 1, 2])
    }

    @Test func anEventAfterTheReplyGoesStraightToThePageInItsTurn() async {
        let provider = PageRouterFrozenDeliveryTests.StreamProvider(["cmux.held.log": .ordered])
        let (router, sent) = router(provider)
        _ = await router.handle(["t": "sub", "id": 1, "stream": "cmux.held.log"])
        provider.emit("cmux.held.log", 0..<1)
        #expect(sent.numbers == [0], "an event after the reply waited for a later turn")
    }

    /// Answered, a held stream's events take its policy at once: a `.latest` stream reports each
    /// replaced event dropped in the turn it was replaced.
    @Test func anEventAfterTheReplyTakesTheHoldAndItsPolicy() async {
        let provider = PageRouterFrozenDeliveryTests.StreamProvider(["cmux.held.state": .latest])
        let (router, sent) = router(provider)
        _ = await router.handle(["t": "sub", "id": 1, "stream": "cmux.held.state"])
        router.holdDelivery()
        provider.emit("cmux.held.state", 0..<3)
        #expect(router.heldEventCount == 1)
        #expect(provider.dropped.compactMap { $0["n"]?.doubleValue } == [0, 1])
        router.releaseDelivery()
        #expect(sent.numbers == [2])
    }
}
