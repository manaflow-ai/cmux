import CmuxNextSettings
@testable import CmuxNextPages
import Testing

/// A pane's chats as views of one page (goal memory-per-chat): the router sends each call and
/// subscription that names a view to that view's providers, keeps the page's own routes for the
/// rest, and ends a view's streams and provider state when the view goes.
@MainActor @Suite
struct PageRouterViewTests {
    static let descriptor = PageDescriptor(id: "cmux.view-test", resource: "view-test", namespaces: ["cmux.chat.", "cmux.panel."])

    final class Provider: PageProvider {
        let name: String
        var calls: [(String, JSONValue)] = []
        var filters: [JSONValue] = []
        var cancelled = 0
        var closed = 0
        var onEvent: (@MainActor (JSONValue) -> Void)?

        init(_ name: String) { self.name = name }

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            calls.append((op, params))
            return .string(name)
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            filters.append(filter)
            self.onEvent = onEvent
            return PageSubscription { [weak self] in self?.cancelled += 1 }
        }

        func pageDidClose() { closed += 1 }
    }

    let own = Provider("own")
    let panel = Provider("panel")
    let router: PageRouter

    init() {
        router = PageRouter(descriptor: Self.descriptor, routes: [
            PageRoute(prefix: "cmux.chat.", provider: own), PageRoute(prefix: "cmux.panel.", provider: panel),
        ])
    }

    func call(_ op: String, _ params: JSONValue) async -> JSONValue {
        await router.handle(["t": "call", "id": 1, "op": .string(op), "params": params])
    }

    @Test func aPageWithNoViewsPassesTheFieldThrough() async {
        let reply = await call("cmux.chat.setAttachmentView", ["view": "strip"])
        #expect(reply["value"]?.stringValue == "own")
        #expect(own.calls.first?.1 == ["view": "strip"])
    }

    @Test func aCallNamingAViewReachesThatViewWithoutTheField() async {
        let a = Provider("a"), b = Provider("b")
        router.addView("a", routes: [PageRoute(prefix: "cmux.chat.", provider: a)])
        router.addView("b", routes: [PageRoute(prefix: "cmux.chat.", provider: b)])
        #expect(await call("cmux.chat.send", ["view": "b", "text": "hi"])["value"]?.stringValue == "b")
        #expect(b.calls.first?.1 == ["text": "hi"])
        #expect(a.calls.isEmpty)
        // A namespace the view does not serve falls back to the page's own provider, field removed.
        #expect(await call("cmux.panel.open", ["view": "a"])["value"]?.stringValue == "panel")
        #expect(panel.calls.first?.1 == .object([:]))
        // No view: the page's own chat.
        #expect(await call("cmux.chat.send", .object([:]))["value"]?.stringValue == "own")
        #expect(router.viewIDs == ["a", "b"])
    }

    @Test func anUnknownViewIsRefused() async {
        router.addView("a", routes: [PageRoute(prefix: "cmux.chat.", provider: Provider("a"))])
        let reply = await call("cmux.chat.send", ["view": "gone"])
        #expect(reply["code"]?.stringValue == PageRouter.unknownViewCode)
        let sub = await router.handle(["t": "sub", "id": 2, "stream": "cmux.chat.events", "filter": ["view": 7]])
        #expect(sub["code"]?.stringValue == PageRouter.unknownViewCode)
    }

    @Test func removingAViewEndsItsStreamsAndState() async throws {
        let a = Provider("a"), b = Provider("b")
        router.addView("a", routes: [PageRoute(prefix: "cmux.chat.", provider: a)])
        router.addView("b", routes: [PageRoute(prefix: "cmux.chat.", provider: b)])
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        let subA = await router.handle(["t": "sub", "id": 1, "stream": "cmux.chat.events", "filter": ["view": "a"]])
        _ = await router.handle(["t": "sub", "id": 2, "stream": "cmux.chat.events", "filter": ["view": "b"]])
        #expect(a.filters.first == .object([:]))
        #expect(router.subscriptionCount == 2)
        let subID = try #require(subA["value"]?["sub"]?.doubleValue)
        a.onEvent?(["n": 1])
        #expect(sent.last?["sub"]?.doubleValue == subID)

        router.removeView("a")
        #expect(a.cancelled == 1)
        #expect(a.closed == 1)
        #expect(b.cancelled == 0 && b.closed == 0)
        #expect(router.subscriptionCount == 1)
        let count = sent.count
        a.onEvent?(["n": 2])
        #expect(sent.count == count, "an event of a removed view still reached the page")
        #expect(await call("cmux.chat.send", ["view": "a"])["code"]?.stringValue == PageRouter.unknownViewCode)
    }

    @Test func removingAViewNeverClosesThePagesOwnProviders() {
        router.addView("a", routes: [PageRoute(prefix: "cmux.panel.", provider: panel)])
        router.removeView("a")
        #expect(panel.closed == 0)
    }

    @Test func closingThePageClosesEveryViewOnce() {
        let a = Provider("a")
        router.addView("a", routes: [PageRoute(prefix: "cmux.chat.", provider: a), PageRoute(prefix: "cmux.panel.", provider: a)])
        router.close()
        #expect(a.closed == 1)
        #expect(own.closed == 1)
    }

    @Test func aHostCallNamesItsView() async throws {
        var sent: [JSONValue] = []
        router.send = { sent.append($0) }
        let task = Task { try await router.callPage("cmux.page.command", params: ["command": "find"], view: "a") }
        for _ in 0..<100 where sent.isEmpty { await Task.yield() }
        let envelope = try #require(sent.first)
        #expect(envelope["params"] == ["command": "find", "view": "a"])
        _ = await router.handle(["t": "ok", "id": envelope["id"] ?? 1, "value": true])
        #expect(try await task.value == .bool(true))
    }
}
