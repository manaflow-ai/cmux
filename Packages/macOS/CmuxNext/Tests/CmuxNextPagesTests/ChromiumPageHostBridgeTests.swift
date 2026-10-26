import JavaScriptCore
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing

/// ``ChromiumPageHostBridge`` against a fake Chromium page: messages in, replies back into the
/// sender's context, fire-and-forget handlers, and the script FIFO.
@MainActor
struct ChromiumPageHostBridgeTests {
    @Test func aPageCallIsAnsweredInTheContextThatSentIt() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        var received: PageHostMessage?
        bridge.install { message in
            received = message
            return ["ok": true]
        }
        let resolve = ChromiumPageHostWire.resolveExpression(seq: 1, reply: ["ok": true])
        let answered: Bool? = await PageTestWait.value("reply") { done in
            page.onCall = { if page.calls.contains(where: { $0.params["expression"] as? String == resolve }) { done(true) } }
            #expect(bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPage", "seq": 1, "body": ["op": "ping"]])))
        }
        #expect(answered == true)
        let message = try #require(received)
        #expect(message.frameURL?.absoluteString == page.senderURL)
        #expect(message.isMainFrame)
        #expect((message.body as? [String: Any])?["op"] as? String == "ping")
        let contexts = page.calls.filter { $0.method == "Runtime.evaluate" }.map { $0.params["contextId"] as? Int }
        #expect(contexts == [9, 9])
        #expect(bridge.answered == 1)
    }

    @Test func fireAndForgetMessagesComeOnlyFromTheMainFrame() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        var reached = 0
        bridge.onFirstMessage = { reached += 1 }
        page.senderIsTop = false
        let fromChild: String? = await PageTestWait.value("child") { done in
            bridge.onMessage = { name, _ in done("message " + name) }
            page.onCall = { done("checked") }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPagePainted", "body": 12]))
        }
        #expect(fromChild == "checked")
        page.senderIsTop = true
        let fromMain: String? = await PageTestWait.value("main") { done in
            bridge.onMessage = { name, body in done("\(name) \(body)") }
            page.onCall = nil
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPagePainted", "body": 12]))
        }
        #expect(fromMain == "cmuxPagePainted 12")
        #expect(reached == 1)
    }

    @Test func aNameTheBridgeDoesNotKnowGetsNoAnswer() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        var handled = false
        bridge.install { _ in
            handled = true
            return nil
        }
        bridge.onMessage = { _, _ in handled = true }
        let checked: Bool? = await PageTestWait.value("sender check") { done in
            page.onCall = { done(true) }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "somethingElse", "seq": 2, "body": 1]))
        }
        #expect(checked == true)
        #expect(!handled)
        #expect(!bridge.receive(devToolsMessage: #"{"method":"Page.loadEventFired","params":{}}"#))
    }

    /// Perf budgets 2026-10-21: each chat push is one script; a streaming reply queued hundreds and
    /// the bridge sent one DevTools round trip per script, so the queue grew while the reply streamed.
    /// The scripts queued when a send starts go in one `Runtime.evaluate`, in order.
    @Test func queuedScriptsRunInOrderInOneRoundTrip() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        let ran: [String]? = await PageTestWait.value("scripts") { done in
            page.onCall = {
                let scripts = page.calls.compactMap { $0.params["expression"] as? String }
                if scripts.joined().contains("c()") { done(scripts) }
            }
            for index in 0..<50 { bridge.evaluate("push(\(index))") }
            bridge.evaluate("a()")
            bridge.evaluate("b()")
            bridge.evaluate("c()")
        }
        let sent = ran ?? []
        #expect(sent.count <= 2, "53 queued scripts took \(sent.count) round trips")
        let order = sent.joined()
        let positions = ["push(0)", "push(49)", "a()", "b()", "c()"].compactMap { order.range(of: $0)?.lowerBound }
        #expect(positions.count == 5 && positions == positions.sorted(), "in order")
    }

    /// A script that throws does not stop the scripts batched after it.
    @Test func aThrowingScriptDoesNotStopTheBatch() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var ran = [];")
        context.evaluateScript(ChromiumPageHostBridge.batch(["ran.push(1)", "throw new Error('x')", "ran.push(3)", "const k = 4; ran.push(k)"]))
        #expect(context.evaluateScript("ran.join(',')").toString() == "1,3,4")
    }

    @Test func setupTurnsOnTheDomainsBeforeTheBindingAndScripts() {
        let calls = ChromiumPageHostBridge.setupCalls(handlers: ["cmuxPagePainted"], documentScripts: ["one()"])
        #expect(calls.map(\.0) == ["Page.enable", "Runtime.enable", "Runtime.addBinding",
                                   "Page.addScriptToEvaluateOnNewDocument", "Page.addScriptToEvaluateOnNewDocument"])
        #expect(calls[2].1["name"] as? String == ChromiumPageHostBridge.bindingName)
        #expect(calls[4].1["source"] as? String == "one()")
    }

    // MARK: Renderer paths (fork API 29)

    private static let pageA = PageDescriptor(id: "test.a", resource: "a", namespaces: [])
    private static let pageB = PageDescriptor(id: "test.b", resource: "b", namespaces: [])

    private static func payload(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    /// A DevTools agent keeps Chromium from sharing a renderer: on renderer paths, setup, a commit,
    /// a call and its reply, and pushes go to the page without one DevTools call.
    @Test func onRendererPathsThePageHostMakesNoDevToolsCall() async {
        let page = FakeChromiumPage(usesRendererPaths: true)
        page.senderURL = Self.pageA.url().absoluteString
        let bridge = ChromiumPageHostBridge(page: page, descriptor: Self.pageA, fireAndForget: ["cmuxPagePainted"])
        try? await bridge.setUp(documentScripts: ["one()"])
        bridge.install { _ in ["ok": true] }
        let resolve = ChromiumPageHostWire.resolveExpression(seq: 1, reply: ["ok": true])
        let ran: [String]? = await PageTestWait.value("reply") { done in
            page.onEvaluate = { if page.evaluations.contains(where: { $0.contains(resolve) }) { done(page.evaluations) } }
            bridge.rebind()
            bridge.evaluate("push()")
            page.post(Self.payload(["name": "cmuxPage", "seq": 1, "body": ["op": "ping"]]))
        }
        let sent = ran ?? []
        #expect(sent.contains { $0.contains(ChromiumPageHostBridge.addHandlersName) && $0.contains("cmuxPagePainted") })
        #expect(sent.contains { $0.contains("one()") })
        #expect(sent.contains { $0.contains("push()") })
        #expect(page.calls.isEmpty, "DevTools calls on renderer paths: \(page.calls.map(\.method))")
    }

    /// Two pages share one renderer, so a compromised renderer can post anything as either: page
    /// A's frame posts a call whose payload names page B. The message is A's (the frame that
    /// delivered it): B never sees it, and when A's frame holds B's document the call is refused.
    @Test func aPayloadThatNamesAnotherPageIsRefused() async {
        let renderer = FakeChromiumRenderer()
        let pageA = renderer.page(browserID: 1, showing: Self.pageA)
        let pageB = renderer.page(browserID: 2, showing: Self.pageB)
        let bridgeA = ChromiumPageHostBridge(page: pageA, descriptor: Self.pageA)
        let bridgeB = ChromiumPageHostBridge(page: pageB, descriptor: Self.pageB)
        var seenByA: [URL?] = []
        var seenByB = 0
        bridgeA.install { message in
            seenByA.append(message.frameURL)
            return ["ok": true]
        }
        bridgeB.install { _ in
            seenByB += 1
            return ["ok": true]
        }
        pageA.onEvent = { if case .hostMessage(let sender, let text) = $0 { bridgeA.receive(hostMessage: text, from: sender) } }
        pageB.onEvent = { if case .hostMessage(let sender, let text) = $0 { bridgeB.receive(hostMessage: text, from: sender) } }
        let namesB = Self.payload(["name": "cmuxPage", "seq": 1, "body": ["op": "ping"], "browserID": 2,
                                   "page": Self.pageB.id, "frameURL": Self.pageB.url().absoluteString])

        func reply(_ seq: Int) -> String { ChromiumPageHostWire.resolveExpression(seq: seq, reply: ["ok": true]) }
        let first: Bool? = await PageTestWait.value("A answered") { done in
            pageA.onEvaluate = { if pageA.evaluations.contains(reply(1)) { done(true) } }
            renderer.post(from: 1, namesB)
        }
        #expect(first == true)
        #expect(seenByA.map { $0?.host } == [Self.pageA.id], "the message was not page A's own frame's")
        #expect(seenByB == 0 && pageB.evaluations.isEmpty, "page B saw a message of page A's frame")

        // A's frame now holds B's document: its posts are refused, whatever they say. A trusted post
        // after it shows the refused one was handled (messages are taken in order).
        pageA.senderURL = Self.pageB.url().absoluteString
        renderer.post(from: 1, namesB)
        pageA.senderURL = Self.pageA.url().absoluteString
        let second: Bool? = await PageTestWait.value("A answered again") { done in
            pageA.onEvaluate = { if pageA.evaluations.contains(reply(2)) { done(true) } }
            renderer.post(from: 1, Self.payload(["name": "cmuxPage", "seq": 2, "body": ["op": "ping"]]))
        }
        #expect(second == true)
        #expect(seenByA.count == 2, "a call from a frame holding page B's document reached page A's host")
        #expect(pageA.evaluations.filter { $0 == reply(1) }.count == 1, "the refused call got a reply")
        #expect(seenByB == 0)
        #expect(pageA.calls.isEmpty && pageB.calls.isEmpty)
    }

    /// The renderer scripts: the API only in a `cmux-page:` main frame, a post handed across worlds
    /// to `cmuxPost` on the channel, the reply resolving the call, and handlers added at commit.
    @Test func theRendererScriptsPostOnTheChannelOnlyInACmuxPage() throws {
        func document(at scheme: String) throws -> JSContext {
            let context = try #require(JSContext())
            context.evaluateScript("""
            var window = globalThis; var top = globalThis; var posted = [];
            var location = { protocol: "\(scheme)" };
            function CustomEvent(type, init) { this.type = type; this.detail = init.detail; }
            var document = { listeners: {}, addEventListener(type, f) { (this.listeners[type] ??= []).push(f); },
              dispatchEvent(e) { for (const f of this.listeners[e.type] ?? []) f(e); return true; } };
            function cmuxPost(channel, text) { posted.push([channel, text]); }
            """)
            for script in ChromiumPageHostBridge.rendererScripts(handlers: ["cmuxPagePainted"], world: "w", channel: "cmuxPageHost") {
                context.evaluateScript(script.source)
            }
            return context
        }
        let page = try document(at: "cmux-page:")
        page.evaluateScript("""
        var replied = null;
        webkit.messageHandlers.cmuxPage.postMessage({ op: "ping" }).then((r) => { replied = r; });
        webkit.messageHandlers.cmuxPagePainted.postMessage(3);
        \(ChromiumPageHostBridge.resolveName)(1, { ok: true });
        \(ChromiumPageHostBridge.addHandlersName)(["extra"]);
        """)
        #expect(page.evaluateScript("posted.map((p) => p[0] + ' ' + p[1]).join('|')").toString()
            == #"cmuxPageHost {"name":"cmuxPage","seq":1,"body":{"op":"ping"}}|cmuxPageHost {"name":"cmuxPagePainted","body":3}"#)
        #expect(page.evaluateScript("typeof webkit.messageHandlers.extra.postMessage").toString() == "function")
        #expect(page.evaluateScript("replied && replied.ok").toBool())
        let web = try document(at: "https:")
        #expect(web.evaluateScript("typeof webkit").toString() == "undefined", "a web page got the page host API")
        #expect(web.evaluateScript("Object.keys(document.listeners).length").toInt32() == 0)
    }
}

/// One renderer process shared by several fake pages: a post goes to the page of the browser that
/// delivered it, as the CEF runtime routes a page message by its browser id.
@MainActor
private final class FakeChromiumRenderer {
    private var pages: [Int: FakeChromiumPage] = [:]

    func page(browserID: Int, showing descriptor: PageDescriptor) -> FakeChromiumPage {
        let page = FakeChromiumPage(usesRendererPaths: true, browserID: browserID)
        page.senderURL = descriptor.url().absoluteString
        pages[browserID] = page
        return page
    }

    func post(from browserID: Int, _ payload: String) {
        pages[browserID]?.post(payload)
    }
}
