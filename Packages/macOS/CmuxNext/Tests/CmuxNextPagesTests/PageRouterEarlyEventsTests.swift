@testable import CmuxNextPages
import CmuxNextSettings
import Testing

/// A provider may send its current state from inside `subscribe` (the icon picker's open session).
/// The router holds those events until the reply that names the subscription reaches the page,
/// then sends them in order; with nothing held, later events go to the page at once.
/// #24617 inverted the check: the events sent during `subscribe` were dropped, and a subscription
/// with nothing held queued its next events behind a main-actor task.
@MainActor @Suite(.serialized)
struct PageRouterEarlyEventsTests {
    private let descriptor = PageDescriptor(id: "test.early-page", resource: "early-page", namespaces: ["test.early-page."])

    @Test func eventsSentDuringSubscribeReachThePageAfterTheReplyInOrder() async throws {
        let provider = EarlyProvider(initial: [["n": 1], ["n": 2]])
        let router = PageRouter(descriptor: descriptor, routes: [PageRoute(prefix: descriptor.namespaces[0], provider: provider)])
        var seen: [Double] = []
        var third: CheckedContinuation<Void, Never>?
        router.send = { deliveries in
            for delivery in deliveries {
                guard let n = delivery.envelope["data"]?["n"]?.doubleValue else { continue }
                seen.append(n)
                if n == 3 { third?.resume(); third = nil }
            }
        }
        let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(descriptor.namespaces[0] + "changed")])
        #expect(reply["t"]?.stringValue == "ok")
        let emit = try #require(provider.emit)
        await withCheckedContinuation { continuation in
            third = continuation
            emit(["n": 3])
        }
        #expect(seen == [1, 2, 3], "the events sent during subscribe were lost or reordered")
        router.close()
    }

    @Test func withNothingHeldTheNextEventGoesAtOnce() async throws {
        let provider = EarlyProvider(initial: [])
        let router = PageRouter(descriptor: descriptor, routes: [PageRoute(prefix: descriptor.namespaces[0], provider: provider)])
        var sends = 0
        router.send = { _ in sends += 1 }
        let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(descriptor.namespaces[0] + "changed")])
        #expect(reply["t"]?.stringValue == "ok")
        let emit = try #require(provider.emit)
        emit(["n": 1])
        #expect(sends == 1, "an event after the reply waited for a main-actor task")
        router.close()
    }
}

/// A provider with one stream that sends `initial` from inside `subscribe`, then what the test emits.
@MainActor
private final class EarlyProvider: PageProvider {
    private let initial: [JSONValue]
    var emit: (@MainActor (JSONValue) -> Void)?

    init(initial: [JSONValue]) { self.initial = initial }

    func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

    func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        emit = onEvent
        for data in initial { onEvent(data) }
        return PageSubscription {}
    }
}
