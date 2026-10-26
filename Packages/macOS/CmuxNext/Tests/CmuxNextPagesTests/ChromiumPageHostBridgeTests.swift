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
    /// a call and its reply, pushes and a key typed before the input was ready go to the page
    /// without one DevTools call.
    @Test func onRendererPathsThePageHostMakesNoDevToolsCall() async {
        let page = FakeChromiumPage(usesRendererPaths: true)
        page.senderURL = Self.pageA.url().absoluteString
        let bridge = ChromiumPageHostBridge(page: page, descriptor: Self.pageA, fireAndForget: ["cmuxPagePainted"])
        try? await bridge.setUp(documentScripts: ["one()"])
        bridge.install { _ in ["ok": true] }
        let resolve = ChromiumPageHostWire.resolveExpression(seq: 1, reply: ["ok": true], document: "d1")
        let ran: [String]? = await PageTestWait.value("reply") { done in
            page.onEvaluate = { if page.evaluations.contains(where: { $0.contains(resolve) }) { done(page.evaluations) } }
            bridge.rebind()
            bridge.evaluate("push()")
            page.post(Self.payload(["name": "cmuxPage", "seq": 1, "doc": "d1", "body": ["op": "ping"]]))
        }
        let sent = ran ?? []
        #expect(sent.contains { $0.contains(ChromiumPageHostBridge.addHandlersName) && $0.contains("cmuxPagePainted") })
        #expect(sent.contains { $0.contains("one()") })
        #expect(sent.contains { $0.contains("push()") })

        let edit = PageInputReadiness.editScript(.insert("k"))
        page.evaluationAnswer = { $0.contains(edit) ? "true" : nil }
        #expect(await PageWebView.apply(.insert("k"), token: nil, expectedEpoch: nil, in: page))
        #expect(page.calls.isEmpty, "DevTools calls on renderer paths: \(page.calls.map(\.method))")
    }

    /// The page's text cannot name its sender: page A's document posts calls whose text names page
    /// B (also as a whole channel envelope). Each is A's, by the URL the channel world read; B's
    /// bridge never sees one. When A's tab holds B's document, its call is refused and still settles.
    @Test func aPayloadThatNamesAnotherPageIsRefused() async {
        let pageA = FakeChromiumPage(usesRendererPaths: true)
        let pageB = FakeChromiumPage(usesRendererPaths: true)
        pageA.senderURL = Self.pageA.url().absoluteString
        pageB.senderURL = Self.pageB.url().absoluteString
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
        pageA.onEvent = { if case .hostMessage(let envelope) = $0 { bridgeA.receive(hostMessage: envelope) } }
        pageB.onEvent = { if case .hostMessage(let envelope) = $0 { bridgeB.receive(hostMessage: envelope) } }
        let urlB = Self.pageB.url().absoluteString
        func call(_ seq: Int) -> String {
            Self.payload(["name": "cmuxPage", "seq": seq, "doc": "a", "body": ["op": "ping"], "page": Self.pageB.id,
                          "frameURL": urlB, "url": urlB])
        }
        func reply(_ seq: Int, _ value: Any = ["ok": true]) -> String {
            ChromiumPageHostWire.resolveExpression(seq: seq, reply: value, document: "a")
        }

        let first: Bool? = await PageTestWait.value("A answered") { done in
            pageA.onEvaluate = { if pageA.evaluations.contains(reply(1)) { done(true) } }
            pageA.post(call(1))
        }
        #expect(first == true)
        // A whole envelope naming B as the page's text: still A's document's message.
        let forged = ChromiumPageHostWire.ChannelPost(url: URL(string: urlB), message: call(2)).envelope
        bridgeA.receive(hostMessage: ChromiumPageHostWire.ChannelPost(url: URL(string: pageA.senderURL), message: forged).envelope)
        #expect(seenByA.map { $0?.host } == [Self.pageA.id], "the message was not page A's own document's")
        #expect(seenByB == 0 && pageB.evaluations.isEmpty, "page B saw a message of page A's document")

        // A's tab now holds B's document: its call is refused, answered with the refusal.
        pageA.senderURL = urlB
        let refused: Bool? = await PageTestWait.value("A refused") { done in
            pageA.onEvaluate = { if pageA.evaluations.contains(reply(3, ChromiumPageHostBridge.refusedReply)) { done(true) } }
            pageA.post(call(3))
        }
        #expect(refused == true)
        #expect(seenByA.count == 1, "a call from a frame holding page B's document reached page A's host")
        #expect(seenByB == 0)
        #expect(pageA.calls.isEmpty && pageB.calls.isEmpty)
    }

    /// The channel world's envelope: the URL it read and the page's text, nothing else trusted.
    @Test func aChannelPostCarriesTheDocumentURLAndThePagesText() throws {
        let post = ChromiumPageHostWire.ChannelPost(url: URL(string: "cmux-page://test.a/x"), message: #"{"name":"cmuxPage"}"#)
        #expect(ChromiumPageHostWire.ChannelPost(envelope: post.envelope) == post)
        #expect(ChromiumPageHostWire.ChannelPost(envelope: #"{"url":"cmux-page://test.a/"}"#) == nil)
        #expect(ChromiumPageHostWire.resolveExpression(seq: 2, reply: nil, document: "d")
            == #"globalThis.\#(ChromiumPageHostBridge.resolveName)?.(2, null, "d");"#)
    }

    /// A fake renderer document for the renderer scripts: one global for both worlds.
    private static func document(at scheme: String, posts: Bool = true, handlers: [String] = ["cmuxPagePainted"],
                                 documentScripts: [String] = []) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var window = globalThis; var top = globalThis; var posted = [];
        globalThis.console = { error() {}, warn() {}, log() {} };
        function addEventListener() {}
        function requestAnimationFrame() {}
        var location = { protocol: "\(scheme)", href: "\(scheme)//test.a/index.html", pathname: "/index.html", hash: "" };
        function CustomEvent(type, init) { this.type = type; this.detail = init.detail; }
        var document = { listeners: {}, activeElement: null, body: {}, readyState: "loading", documentElement: null,
          addEventListener(type, f) { (this.listeners[type] ??= []).push(f); },
          dispatchEvent(e) { for (const f of this.listeners[e.type] ?? []) f(e); return true; } };
        \(posts ? "function cmuxPost(channel, text) { posted.push([channel, text]); }" : "")
        """)
        for script in ChromiumPageHostBridge.rendererScripts(handlers: handlers, documentScripts: documentScripts,
                                                             world: "w", channel: "cmuxPageHost") {
            context.evaluateScript(script.source)
        }
        return context
    }

    /// The posts of a fake document, as Swift reads them.
    private static func posted(_ context: JSContext) -> [(channel: String, post: ChromiumPageHostWire.ChannelPost)] {
        let count = Int(context.evaluateScript("posted.length").toInt32())
        return (0..<count).compactMap { index in
            let channel = context.evaluateScript("posted[\(index)][0]").toString() ?? ""
            let text = context.evaluateScript("posted[\(index)][1]").toString() ?? ""
            return ChromiumPageHostWire.ChannelPost(envelope: text).map { (channel, $0) }
        }
    }

    /// The renderer scripts: the API only in a `cmux-page:` main frame, a post handed across worlds
    /// to `cmuxPost` with the document's URL, the reply settling only the call of its own document,
    /// and handlers added at commit.
    @Test func theRendererScriptsPostOnTheChannelOnlyInACmuxPage() throws {
        let page = try Self.document(at: "cmux-page:")
        page.evaluateScript("""
        var replied = null;
        webkit.messageHandlers.cmuxPage.postMessage({ op: "ping" }).then((r) => { replied = r; });
        webkit.messageHandlers.cmuxPagePainted.postMessage(3);
        \(ChromiumPageHostBridge.addHandlersName)(["extra"]);
        """)
        let posts = Self.posted(page)
        try #require(posts.count == 2)
        #expect(posts.map(\.channel) == ["cmuxPageHost", "cmuxPageHost"])
        #expect(posts.allSatisfy { $0.post.url?.absoluteString == "cmux-page://test.a/index.html" })
        let call = try #require(ChromiumPageHostWire.Message(payload: posts[0].post.message))
        #expect(call.name == "cmuxPage" && call.seq == 1 && (call.body as? [String: Any])?["op"] as? String == "ping")
        let document = try #require(call.document)
        #expect(ChromiumPageHostWire.Message(payload: posts[1].post.message)?.name == "cmuxPagePainted")
        #expect(page.evaluateScript("typeof webkit.messageHandlers.extra.postMessage").toString() == "function")

        // A reply for another document's call 1 (the one this document replaced) settles nothing.
        page.evaluateScript(ChromiumPageHostWire.resolveExpression(seq: 1, reply: ["ok": true], document: "an older document"))
        #expect(page.evaluateScript("replied === null").toBool(), "another document's reply settled this call")
        page.evaluateScript(ChromiumPageHostWire.resolveExpression(seq: 1, reply: ["ok": true], document: document))
        #expect(page.evaluateScript("replied && replied.ok").toBool())

        let web = try Self.document(at: "https:", documentScripts: ["globalThis.ran = true;"])
        #expect(web.evaluateScript("typeof webkit").toString() == "undefined", "a web page got the page host API")
        #expect(web.evaluateScript("typeof ran").toString() == "undefined", "a web page ran a page document script")
        #expect(web.evaluateScript("Object.keys(document.listeners).length").toInt32() == 0)
    }

    /// Without the page channel a call settles at once with the host's failure, instead of waiting.
    @Test func aCallWithNoPageChannelFailsAtOnce() throws {
        let page = try Self.document(at: "cmux-page:", posts: false)
        page.evaluateScript("""
        var replied = null;
        webkit.messageHandlers.cmuxPage.postMessage({}).then((r) => { replied = r; });
        """)
        #expect(page.evaluateScript("replied && replied.ok === false && replied.error.code").toString() == "native.page_host_unavailable")
    }

    /// The page's document scripts and every named handler are there before the page's own first
    /// script: a page that focuses its input at once still reports it ready (the input readiness
    /// script ran at document start, not at commit), and a page script finds its handler.
    @Test func thePagesDocumentScriptsRunBeforeThePage() throws {
        let page = try Self.document(at: "cmux-page:", handlers: PageWebView.chromiumFireAndForget + ["extra"],
                                     documentScripts: PageChromiumDocumentScripts.shared
                                         + ["globalThis.sawExtra = typeof webkit.messageHandlers.extra.postMessage;"])
        #expect(page.evaluateScript("sawExtra").toString() == "function")
        // The page's own code: an autofocused input.
        page.evaluateScript("""
        document.activeElement = { tagName: "INPUT", type: "text", isContentEditable: false,
          closest() { return null; }, getAttribute() { return null; }, hasAttribute() { return false; } };
        document.dispatchEvent({ type: "focusin" });
        """)
        let ready = Self.posted(page).compactMap { ChromiumPageHostWire.Message(payload: $0.post.message) }
            .filter { $0.name == PageInputReadiness.handlerName }
        #expect(ready.contains { $0.body as? Bool == true }, "the autofocused input never reported ready")
    }

    /// A page view's document scripts minus the renderer's shared ones: only its own values (theme,
    /// `data-*` attributes) run at commit, and nothing the renderer has runs twice.
    @Test func onlyAViewsOwnScriptsRunAtCommit() {
        let theme = "window.cmuxTheme && window.cmuxTheme.apply({});"
        let scripts = PageChromiumDocumentScripts(scripts: [
            (PageInputReadiness.script, false, true), (theme, false, true), (PagePaintProbe.script, true, true),
        ])
        #expect(scripts.perView == [PageChromiumDocumentScripts.chromiumSource((theme, false, true))])
        #expect(PageChromiumDocumentScripts.shared.contains(PageChromiumDocumentScripts.navigationScript))
    }
}
