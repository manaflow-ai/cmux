@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// The page host's rules (plans/cmux-next/react-pages.md 1): only admitted ops reach a provider,
/// the host stamps origin `user` and refuses one from the page, events are numbered per
/// subscription, and closing the page cancels everything.
@MainActor
@Suite struct PageRouterTests {
    final class Recorder: PageProvider {
        var calls: [(op: String, params: JSONValue, context: PageCallContext)] = []
        var emit: (@MainActor (JSONValue) -> Void)?
        var filters: [JSONValue] = []
        var cancelled = 0
        var failure: PageError?

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            calls.append((op, params, context))
            if let failure { throw failure }
            return ["echo": .string(op)]
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            filters.append(filter)
            emit = onEvent
            return PageSubscription { [weak self] in self?.cancelled += 1 }
        }
    }

    let page = PageDescriptor(
        id: "cmux.settings", resource: "settings", namespaces: ["cmux.settings."],
        nativeOps: [PageNativeOp.actionRun], denied: ["cmux.settings.domains.publish"])

    func router() -> (PageRouter, Recorder, Recorder, Box) {
        let daemon = Recorder()
        let native = Recorder()
        let router = PageRouter(descriptor: page, routes: [
            PageRoute(prefix: "cmux.settings.", provider: daemon), PageRoute(prefix: "cmux.app.", provider: native),
        ])
        let sent = Box()
        router.send = { sent.items.append($0) }
        return (router, daemon, native, sent)
    }

    final class Box { var items: [JSONValue] = [] }

    @Test func admittedCallsReachTheirProviderWithOriginUser() async {
        let (router, daemon, native, _) = router()
        let reply = await router.handle(["t": "call", "id": 1, "op": "cmux.settings.list", "params": ["section": "appearance"]])
        #expect(reply == ["t": "ok", "id": 1, "value": ["echo": "cmux.settings.list"]])
        #expect(daemon.calls.map(\.op) == ["cmux.settings.list"])
        #expect(daemon.calls.first?.params == ["section": "appearance"])
        #expect(daemon.calls.first?.context == PageCallContext(page: "cmux.settings", origin: "user"))
        _ = await router.handle(["t": "call", "id": 2, "op": .string(PageNativeOp.actionRun), "params": ["action": "x"]])
        #expect(native.calls.map(\.op) == [PageNativeOp.actionRun])
    }

    @Test func everythingElseIsUnknownAndReachesNoProvider() async {
        let (router, daemon, native, _) = router()
        for op in ["terminal.input.write", "cmux.history.entries.list", "cmux.settings", "cmux.settings.domains.publish",
                   "cmux.app.clipboard.write", "action.run"] {
            let reply = await router.handle(["t": "call", "id": 3, "op": .string(op), "params": [:]])
            #expect(reply["code"] == "cmux.protocol.unknown_op", "\(op) reached a provider")
        }
        #expect(daemon.calls.isEmpty && native.calls.isEmpty)
    }

    @Test func aPageSentOriginOrNonObjectParamsAreRefused() async {
        let (router, daemon, _, _) = router()
        let origin = await router.handle(["t": "call", "id": 4, "op": "cmux.settings.set", "params": ["key": "a", "origin": "mcp"]])
        #expect(origin["code"] == "cmux.protocol.invalid_params")
        let array = await router.handle(["t": "call", "id": 5, "op": "cmux.settings.set", "params": [1, 2]])
        #expect(array["code"] == "cmux.protocol.invalid_params")
        #expect(daemon.calls.isEmpty)
    }

    @Test func providerRefusalsKeepTheirCodeAndRetryable() async {
        let (router, daemon, _, _) = router()
        daemon.failure = PageError(code: "cmux.settings.managed", message: "managed", details: ["reason": "profile"])
        let reply = await router.handle(["t": "call", "id": 6, "op": "cmux.settings.set", "params": [:]])
        #expect(reply == ["t": "err", "id": 6, "code": "cmux.settings.managed", "message": "managed", "retryable": false,
                          "details": ["reason": "profile"]])
    }

    @Test func eventsAreNumberedFromOneAndStopAtUnsubscribe() async {
        let (router, daemon, _, sent) = router()
        let reply = await router.handle(["t": "sub", "id": 7, "stream": "cmux.settings.changed"])
        #expect(reply == ["t": "ok", "id": 7, "value": ["sub": 1]])
        daemon.emit?(["revision": 2])
        daemon.emit?(["revision": 3])
        #expect(sent.items == [
            ["t": "ev", "sub": 1, "seq": 1, "data": ["revision": 2]],
            ["t": "ev", "sub": 1, "seq": 2, "data": ["revision": 3]],
        ])
        _ = await router.handle(["t": "unsub", "sub": 1])
        #expect(daemon.cancelled == 1)
        daemon.emit?(["revision": 4])
        #expect(sent.items.count == 2)
    }

    @Test func subscriptionFiltersReachTheProviderAndAPageOriginIsRefused() async {
        let (router, daemon, _, _) = router()
        _ = await router.handle(["t": "sub", "id": 11, "stream": "cmux.settings.changed", "filter": ["keys": ["a"]]])
        #expect(daemon.filters == [["keys": ["a"]]])
        let refused = await router.handle(["t": "sub", "id": 12, "stream": "cmux.settings.changed", "filter": ["origin": "mcp"]])
        #expect(refused["code"] == "cmux.protocol.invalid_params")
        #expect(daemon.filters.count == 1)
    }

    @Test func closeCancelsSubscriptionsAndRefusesLaterCalls() async {
        let (router, daemon, _, _) = router()
        _ = await router.handle(["t": "sub", "id": 8, "stream": "cmux.settings.changed"])
        router.close()
        #expect(daemon.cancelled == 1)
        #expect(router.subscriptionCount == 0)
        let reply = await router.handle(["t": "call", "id": 9, "op": "cmux.settings.list", "params": [:]])
        #expect(reply["code"] == "cmux.protocol.unavailable")
        router.reset()
        let again = await router.handle(["t": "call", "id": 10, "op": "cmux.settings.list", "params": [:]])
        #expect(again["t"] == "ok")
    }

    @Test func hostCallsResolveFromThePageReply() async throws {
        let (router, _, _, sent) = router()
        let reply = Task { try await router.callPage(PageNativeOp.pageCommand, params: ["command": "find"]) }
        // The call task posts on the main actor; give it bounded turns, then fail instead of hanging.
        for _ in 0..<100 where sent.items.isEmpty { await Task.yield() }
        guard let call = sent.items.first else {
            router.close()
            Issue.record("the host call was never sent")
            return
        }
        #expect(call["op"] == .string(PageNativeOp.pageCommand))
        _ = await router.handle(["t": "ok", "id": call["id"] ?? 0, "value": ["handled": true]])
        #expect(try await reply.value == ["handled": true])
    }

    @Test func closeFailsAPendingHostCall() async {
        let (router, _, _, sent) = router()
        let reply = Task { try await router.callPage(PageNativeOp.pageCommand, params: [:]) }
        for _ in 0..<100 where sent.items.isEmpty { await Task.yield() }
        router.close()
        await #expect(throws: PageError.self) { try await reply.value }
    }
}

@Suite struct PageDescriptorTests {
    @Test func urlsCarryTheRouteAsFragmentAndOneOriginPerPage() {
        let page = PageDescriptor.history
        #expect(page.url().absoluteString == "cmux-page://cmux.history/")
        #expect(page.url(route: "#/history?kind=agent").absoluteString == "cmux-page://cmux.history/#/history?kind=agent")
        #expect(page.owns(URL(string: "cmux-page://cmux.history/index.html")))
        #expect(!page.owns(URL(string: "cmux-page://cmux.settings/")))
        #expect(!page.owns(URL(string: "https://cmux.history/")))
        #expect(page.origin == "cmux-page://cmux.history")
    }

    @Test func schemeHandlerServesOnlyThePagesOwnDirectory() {
        let page = PageDescriptor.history
        let root = URL(fileURLWithPath: "/tmp/cmux-pages-root")
        #expect(PageSchemeHandler.fileURL(for: URL(string: "cmux-page://cmux.history/")!, page: page, root: root)?.lastPathComponent == "index.html")
        #expect(PageSchemeHandler.fileURL(for: URL(string: "cmux-page://cmux.history/a/b.js")!, page: page, root: root)?.path
            == "/tmp/cmux-pages-root/a/b.js")
        #expect(PageSchemeHandler.fileURL(for: URL(string: "cmux-page://cmux.history/../etc/passwd")!, page: page, root: root) == nil)
        #expect(PageSchemeHandler.fileURL(for: URL(string: "cmux-page://cmux.settings/index.html")!, page: page, root: root) == nil)
        #expect(PageSchemeHandler.fileURL(for: URL(string: "cmux-agent://pane/index.html")!, page: page, root: root) == nil)
    }

    @Test func theHistoryPageShipsSelfContainedWithNoNetwork() throws {
        let root = try #require(PageSchemeHandler.bundledRoot(for: .history))
        let html = try String(contentsOf: root.appending(path: "index.html"), encoding: .utf8)
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("data-cmux-page=\"history\""))
        #expect(!html.contains("src=\"http"))
    }
}
