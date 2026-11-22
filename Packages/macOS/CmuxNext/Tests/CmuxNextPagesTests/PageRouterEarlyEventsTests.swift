import CmuxNextSettings
@testable import CmuxNextPages
import Testing

/// Events a provider sends while its `subscribe` runs (its current state: the icon picker's open
/// session, the activity requests, the update island) wait for the reply that names the
/// subscription, then reach the page once, in order. Once the subscription is answered, an event
/// goes straight to the page in its own turn.
@MainActor
struct PageRouterEarlyEventsTests {
    static let descriptor = PageDescriptor(id: "cmux.early-test", resource: "early-test", namespaces: ["cmux.early."])

    /// One stream that sends `eventsDuringSubscribe` numbered events from inside `subscribe`.
    final class StreamProvider: PageProvider {
        var eventsDuringSubscribe = 0
        private var onEvent: (@MainActor (JSONValue) -> Void)?

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            self.onEvent = onEvent
            for n in 0..<eventsDuringSubscribe { onEvent(["n": .number(Double(n))]) }
            return PageSubscription {}
        }

        func emit(_ numbers: Range<Int>) {
            for n in numbers { onEvent?(["n": .number(Double(n))]) }
        }
    }

    private final class Sent {
        var envelopes: [JSONValue] = []
        var numbers: [Double] { envelopes.compactMap { $0["data"]?["n"]?.doubleValue } }
    }

    private func router(_ provider: StreamProvider) -> (PageRouter, Sent) {
        let router = PageRouter(descriptor: Self.descriptor, routes: [PageRoute(prefix: "cmux.early.", provider: provider)])
        let sent = Sent()
        router.send = { sent.envelopes.append($0) }
        return (router, sent)
    }

    /// Lets the main-actor job the router posts after the reply run (bounded: a lost event fails, never hangs).
    private func settle(until done: () -> Bool) async {
        for _ in 0..<1_000 where !done() { await Task.yield() }
    }

    @Test func aStateSentInsideSubscribeReachesThePageAfterTheReply() async {
        let provider = StreamProvider()
        provider.eventsDuringSubscribe = 2
        let (router, sent) = router(provider)
        let reply = await router.handle(["t": "sub", "id": 1, "stream": "cmux.early.state"])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(sent.envelopes.isEmpty, "the state went out before the reply that names its subscription")
        await settle { !sent.numbers.isEmpty }
        #expect(sent.numbers == [0, 1], "the state the provider sent inside subscribe never reached the page")
        provider.emit(2..<3)
        #expect(sent.numbers == [0, 1, 2])
    }

    @Test func anEventAfterTheReplyGoesStraightToThePageInItsTurn() async {
        let provider = StreamProvider()
        let (router, sent) = router(provider)
        _ = await router.handle(["t": "sub", "id": 1, "stream": "cmux.early.log"])
        provider.emit(0..<1)
        #expect(sent.numbers == [0], "an event after the reply waited for a later turn")
    }
}
