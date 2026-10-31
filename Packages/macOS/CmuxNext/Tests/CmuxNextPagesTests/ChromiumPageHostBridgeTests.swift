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

    /// A call past ``ChromiumPageHostBridge/maximumPayloadBytes`` is answered with an error in the
    /// page and never sent: the host drops an oversized payload unanswered, which left the caller's
    /// promise pending for good (a pasted screenshot's chip that never became the picture).
    @Test func anOversizedCallSettlesWithAnErrorInsteadOfWaitingForever() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var sent = []; globalThis.\(ChromiumPageHostBridge.bindingName) = (text) => sent.push(text.length);")
        context.evaluateScript(ChromiumPageHostBridge.pageScript(handlers: []))
        let post = "globalThis.webkit.messageHandlers.\(PageHostTrust.handlerName).postMessage"
        context.evaluateScript("""
        var replies = {};
        \(post)({ t: "call", id: 7, op: "big", params: { data: "x".repeat(\(ChromiumPageHostBridge.maximumPayloadBytes)) } })
          .then((reply) => { replies.big = reply; });
        \(post)({ t: "call", id: 8, op: "wide", params: { data: "é".repeat(\(ChromiumPageHostBridge.maximumPayloadBytes / 2)) } })
          .then((reply) => { replies.wide = reply; });
        \(post)({ t: "call", id: 9, op: "small", params: {} });
        """)
        #expect(context.evaluateScript("sent.length").toInt32() == 1, "only the small call goes to the host")
        for (key, id) in [("big", 7), ("wide", 8)] {
            #expect(context.evaluateScript("replies.\(key) && replies.\(key).t").toString() == "err")
            #expect(context.evaluateScript("replies.\(key) && replies.\(key).id").toInt32() == Int32(id))
            #expect(context.evaluateScript("replies.\(key) && replies.\(key).code").toString() == "cmux.protocol.too_large")
        }
    }

    @Test func setupTurnsOnTheDomainsBeforeTheBindingAndScripts() {
        let calls = ChromiumPageHostBridge.setupCalls(handlers: ["cmuxPagePainted"], documentScripts: ["one()"])
        #expect(calls.map(\.0) == ["Page.enable", "Runtime.enable", "Runtime.addBinding",
                                   "Page.addScriptToEvaluateOnNewDocument", "Page.addScriptToEvaluateOnNewDocument"])
        #expect(calls[2].1["name"] as? String == ChromiumPageHostBridge.bindingName)
        #expect(calls[4].1["source"] as? String == "one()")
    }
}
