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

    /// p01-process-232: the page script and every document script go in one new-document script, so a page's setup
    /// is four host round trips before its first load however many scripts it has; the page script runs first.
    @Test func setupTurnsOnTheDomainsBeforeTheBindingAndScripts() {
        let calls = ChromiumPageHostBridge.setupCalls(handlers: ["cmuxPagePainted"], documentScripts: ["one()", "two()"])
        #expect(calls.map(\.0) == ["Page.enable", "Runtime.enable", "Runtime.addBinding", "Page.addScriptToEvaluateOnNewDocument"])
        #expect(calls[2].1["name"] as? String == ChromiumPageHostBridge.bindingName)
        let source = calls[3].1["source"] as? String ?? ""
        let order = ["__cmuxPageHostInstalled", "one()", "two()"].compactMap { source.range(of: $0)?.lowerBound }
        #expect(order.count == 3 && order == order.sorted(), "the page script, then the document scripts in order")
        let channel = ChromiumPageHostBridge.setupCalls(handlers: [], documentScripts: [], channelEvent: "cmux-page-host-post")
        #expect((channel[3].1["source"] as? String)?.contains(#"const channelEvent = "cmux-page-host-post";"#) == true)
    }

    // MARK: Page channel (p01-process-232)

    /// A page channel post after the commit is delivered in its own turn, judged by the committed document, with no
    /// sender probe: the call costs no DevTools round trip, and its reply goes into the main frame for that document.
    @Test func aPageChannelCallNeedsNoSenderProbe() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        let url = try #require(URL(string: page.senderURL))
        var received: PageHostMessage?
        bridge.install { message in
            received = message
            return ["ok": true]
        }
        bridge.documentCommitted(url)
        let resolve = ChromiumPageHostWire.resolveExpression(seq: 3, reply: ["ok": true], document: "d1")
        let answered: Bool? = await PageTestWait.value("reply") { done in
            page.onCall = { if page.calls.contains(where: { ($0.params["expression"] as? String)?.contains(resolve) == true }) { done(true) } }
            bridge.receive(pageHostPost: Self.text(["name": "cmuxPage", "seq": 3, "doc": "d1", "body": ["op": "draft"]]))
        }
        #expect(answered == true)
        let message = try #require(received)
        #expect(message.frameURL == url && message.isMainFrame)
        #expect(page.calls.count == 1, "only the reply went to the page: \(page.calls.map(\.method))")
        #expect(page.calls.first?.params["contextId"] == nil, "the reply goes to the main frame")
    }

    /// The posts of one task arrive as one array: each message reaches its handler, in order; the fire-and-forget
    /// ones in the post's own turn.
    @Test func aBatchedPostDeliversEachMessageInOrder() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        bridge.documentCommitted(URL(string: page.senderURL))
        var heard: [String] = []
        bridge.onMessage = { name, body in heard.append("\(name) \(body)") }
        var calls: [String] = []
        bridge.install { message in
            calls.append((message.body as? [String: Any])?["op"] as? String ?? "?")
            return nil
        }
        let batch = "[" + [Self.text(["name": "cmuxPagePainted", "body": 1]),
                           Self.text(["name": "cmuxPage", "seq": 1, "body": ["op": "a"]]),
                           Self.text(["name": "cmuxPagePainted", "body": 2]),
                           Self.text(["name": "cmuxPage", "seq": 2, "body": ["op": "b"]])].joined(separator: ",") + "]"
        bridge.receive(pageHostPost: batch)
        #expect(heard == ["cmuxPagePainted 1", "cmuxPagePainted 2"], "fire-and-forget messages arrive in the post's turn")
        let both: Bool? = await PageTestWait.value("calls") { done in
            page.onCall = { if bridge.answered == 2 { done(true) } }
        }
        #expect(both == true)
        #expect(calls == ["a", "b"])
    }

    /// A document the page host sent away (another page's URL) gets no trust from the page it replaced.
    @Test func aPostAfterAForeignCommitIsNotTrusted() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        var received: PageHostMessage?
        bridge.install { message in
            received = message
            return nil
        }
        bridge.documentCommitted(URL(string: "cmux-page://other.page/index.html"))
        let got: Bool? = await PageTestWait.value("call") { done in
            page.onCall = { done(true) }
            bridge.receive(pageHostPost: Self.text(["name": "cmuxPage", "seq": 1, "body": [:]]))
        }
        #expect(got == true)
        let message = try #require(received)
        #expect(message.frameURL?.host == "other.page", "the message is the foreign document's")
        #expect(!PageHostTrust.isTrusted(message, page: PageDescriptor(id: "test.plain", resource: "plain", processGroup: .solo, namespaces: [])))
    }

    /// A post before its cmux page's commit is heard (the commit's event and the post come on different pipes) waits
    /// for that commit, past the initial `about:blank` one, and is judged by it, in order, with no sender probe; a
    /// later commit replays nothing.
    @Test func aPostBeforeTheCommitWaitsForIt() throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        var heard: [String] = []
        bridge.onMessage = { name, body in heard.append("\(name) \(body)") }
        bridge.receive(pageHostPost: Self.text(["name": "cmuxPagePainted", "body": 1]))
        bridge.documentCommitted(URL(string: "about:blank"))
        bridge.receive(pageHostPost: Self.text(["name": "cmuxPagePainted", "body": 2]))
        #expect(heard.isEmpty, "a post was judged before its document's commit")
        bridge.documentCommitted(try #require(URL(string: page.senderURL)))
        #expect(heard == ["cmuxPagePainted 1", "cmuxPagePainted 2"])
        bridge.documentCommitted(URL(string: page.senderURL))
        #expect(heard.count == 2)
        #expect(page.calls.isEmpty, "a DevTools call: \(page.calls.map(\.method))")
    }

    /// One bad message refuses the whole post.
    @Test func aPostWithABadMessageIsRefusedWhole() {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        bridge.documentCommitted(URL(string: page.senderURL))
        var heard = 0
        bridge.onMessage = { _, _ in heard += 1 }
        bridge.receive(pageHostPost: "[" + Self.text(["name": "cmuxPagePainted", "body": 1]) + #",{"name":"cmuxPage","seq":0,"body":1}]"#)
        bridge.receive(pageHostPost: "[]")
        #expect(heard == 0)
        #expect(page.calls.isEmpty)
    }

    private static func text(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }
}
