@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// A provider may send events from inside `subscribe` (the icon picker sends its open session that
/// way, 20066e187f3): the page cannot take them before the reply that names the subscription, so
/// the router holds them and sends them, in order, right after it. A provider that sends nothing
/// during `subscribe` has its events go straight to the page.
///
/// 4abd4049588 inverted the router's check: held events were thrown away (the picker got no
/// session, so no pick was taken), and a stream that held nothing kept holding its later events
/// until a later main-actor turn, so a push sent at once after the subscribe did not reach the page.
@MainActor
struct PageRouterEarlyEventsTests {
    /// A provider that sends `early` from inside `subscribe`, then keeps the stream's `emit`.
    private final class EarlyProvider: PageProvider {
        let early: [JSONValue]
        var emit: ((JSONValue) -> Void)?

        init(early: [JSONValue]) {
            self.early = early
        }

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            for data in early { onEvent(data) }
            emit = onEvent
            return PageSubscription(freezing: .newest) {}
        }
    }

    /// A router with one provider and the events it sent; `whenSent` runs after each send.
    private final class Rig {
        let router: PageRouter
        var sent: [JSONValue] = []
        var whenSent: (() -> Void)?

        init(_ provider: EarlyProvider) {
            router = PageRouter(descriptor: PageDescriptor(id: "test.early", resource: "early", namespaces: ["test."]),
                                routes: [PageRoute(prefix: "test.", provider: provider)])
            router.send = { [unowned self] envelope in
                sent.append(envelope)
                whenSent?()
            }
        }

        /// The `data` of each event sent, in order.
        var events: [JSONValue] { sent.filter { $0["t"]?.stringValue == "ev" }.compactMap { $0["data"] } }

        /// Waits until `count` events were sent.
        func waitForEvents(_ count: Int) async -> Bool {
            let reached: Bool? = await PageTestWait.value("\(count) events sent") { done in
                let check = { [unowned self] in if events.count >= count { done(true) } }
                whenSent = check
                check()
            }
            whenSent = nil
            return reached == true
        }
    }

    @Test func eventsSentDuringSubscribeReachThePageAfterTheReplyInOrder() async throws {
        let provider = EarlyProvider(early: [["n": 1], ["n": 2]])
        let rig = Rig(provider)
        let reply = await rig.router.handle(["t": "sub", "id": 1, "stream": "test.state"])
        let sub = try #require(reply["value"]?["sub"]?.doubleValue)
        // The page has not read the reply yet: nothing may name the subscription before it.
        #expect(rig.sent.isEmpty, "an event went before the subscribe reply")

        // An event sent before the held ones went waits behind them.
        let emit = try #require(provider.emit)
        emit(["n": 3])
        #expect(rig.sent.isEmpty)

        #expect(await rig.waitForEvents(3), "the events sent during subscribe never reached the page")
        #expect(rig.events == [["n": 1], ["n": 2], ["n": 3]])
        #expect(rig.sent.map { $0["sub"]?.doubleValue } == [sub, sub, sub])
        #expect(rig.sent.map { $0["seq"]?.doubleValue } == [1, 2, 3])

        // Released: later events go straight to the page, numbered on.
        emit(["n": 4])
        #expect(rig.events.last == ["n": 4])
        #expect(rig.sent.last?["seq"]?.doubleValue == 4)
    }

    @Test func aStreamThatHeldNothingSendsItsEventsAtOnce() async throws {
        let provider = EarlyProvider(early: [])
        let rig = Rig(provider)
        let reply = await rig.router.handle(["t": "sub", "id": 1, "stream": "test.state"])
        #expect(reply["t"]?.stringValue == "ok")

        let emit = try #require(provider.emit)
        emit(["n": 1])
        #expect(rig.events == [["n": 1]], "a push right after the subscribe waited for a later turn")
        emit(["n": 2])
        #expect(rig.events == [["n": 1], ["n": 2]])
    }
}
