import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import JavaScriptCore
import Testing
@testable import CmuxNextPages

/// The page push channel: with it, the router's envelopes and the replies reach a
/// Chromium page as data (``PageChromiumPage/push(_:)``), never as a script, in send order; without
/// it every delivery is a script, as before. The page script's receiver runs in JavaScriptCore.
@MainActor
struct ChromiumPageHostPushTests {
    private func envelope(_ n: Int) -> JSONValue {
        ["t": "ev", "sub": 7, "seq": .number(Double(n)), "data": ["n": .number(Double(n))]]
    }

    /// Acceptance: 0 evaluates for deliveries on the channel; one push per run, as its JSON array.
    @Test func deliveriesOnTheChannelArePushesWithNoEvaluate() async {
        let page = FakeChromiumPage()
        page.pushChannel = true
        let bridge = ChromiumPageHostBridge(page: page)
        let target = PageScriptTarget(bridge)
        let pipeline = PageScriptPipeline(deliver: { target.deliver($0) }, form: { target.deliveryForm })
        for n in 1...3 { pipeline.send(envelope(n)) }
        #expect(page.pushes == ["[\(envelope(1).compactText)]", "[\(envelope(2).compactText)]", "[\(envelope(3).compactText)]"])
        #expect(page.calls.isEmpty, "a delivery made \(page.calls.count) DevTools calls")
        #expect(page.evaluations.isEmpty)
    }

    /// Without the channel (an older fork, or the feature off) the same sends are scripts.
    @Test func withoutTheChannelDeliveriesStayScripts() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        let target = PageScriptTarget(bridge)
        let pipeline = PageScriptPipeline(deliver: { target.deliver($0) }, form: { target.deliveryForm })
        let ran: [String]? = await PageTestWait.value("scripts") { done in
            page.onCall = {
                let scripts = page.calls.compactMap { $0.params["expression"] as? String }
                if scripts.joined().contains("\"seq\":2") { done(scripts) }
            }
            pipeline.send(envelope(1))
            pipeline.send(envelope(2))
        }
        #expect(page.pushes.isEmpty)
        #expect((ran ?? []).allSatisfy { $0.contains("__cmuxPageReceive") })
    }

    /// A push never overtakes a script queued before it: it leaves once that script's evaluation returned.
    @Test func aPushWaitsForTheScriptsBeforeIt() async {
        let page = FakeChromiumPage()
        page.pushChannel = true
        let bridge = ChromiumPageHostBridge(page: page)
        var order: [String] = []
        page.onCall = { order.append("script") }
        let pushed: Bool? = await PageTestWait.value("push") { done in
            page.onPush = {
                order.append("push")
                done(true)
            }
            bridge.evaluate("theme()")
            bridge.push(envelopes: "[1]")
        }
        #expect(pushed == true)
        #expect(order == ["script", "push"])
    }

    /// A main-frame call's reply is a push of `{"r": seq, "d": doc, "v": reply}` naming the sender's
    /// document; the only DevTools call is the sender check.
    @Test func aReplyOnTheChannelIsAPush() async {
        let page = FakeChromiumPage()
        page.pushChannel = true
        let bridge = ChromiumPageHostBridge(page: page)
        bridge.install { _ in ["ok": true] }
        let reply: String? = await PageTestWait.value("reply") { done in
            page.onPush = { done(page.pushes.last ?? "") }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPage", "seq": 4, "doc": "d-1", "body": ["op": "ping"]]))
        }
        #expect(reply == #"{"r":4,"d":"d-1","v":{"ok":true}}"#)
        #expect(page.calls.map { $0.params["expression"] as? String } == ["[location.href, window === window.top]"])
        #expect(bridge.answered == 1)
    }

    /// A reply still goes out when a new document commits while it waits in the FIFO: only the old
    /// document's envelope runs are dropped, and the reply names its own document.
    @Test func aQueuedReplySurvivesANewDocument() async {
        let page = FakeChromiumPage()
        page.pushChannel = true
        let bridge = ChromiumPageHostBridge(page: page)
        bridge.install { _ in ["ok": true] }
        let reply: String? = await PageTestWait.value("reply") { done in
            page.onCall = {
                // The sender check is in flight: queue a script so the reply waits behind it, then commit.
                guard page.calls.count == 1 else { return }
                bridge.evaluate("slow()")
                bridge.rebind()
            }
            page.onPush = { if let last = page.pushes.last, last.hasPrefix(#"{"r":"#) { done(last) } }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPage", "seq": 1, "doc": "new", "body": ["op": "ping"]]))
        }
        #expect(reply == #"{"r":1,"d":"new","v":{"ok":true}}"#)
    }

    /// A call without a document token gets its reply as a script into its own context, never as a push.
    @Test func aReplyWithoutADocumentTokenStaysAScript() async {
        let page = FakeChromiumPage()
        page.pushChannel = true
        let bridge = ChromiumPageHostBridge(page: page)
        bridge.install { _ in ["ok": true] }
        let resolve: String? = await PageTestWait.value("resolve") { done in
            page.onCall = {
                guard let expression = page.calls.last?.params["expression"] as? String,
                      expression.contains(ChromiumPageHostBridge.resolveName) else { return }
                done(expression)
            }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPage", "seq": 2, "body": ["op": "ping"]]))
        }
        #expect(resolve == ChromiumPageHostWire.resolveExpression(seq: 2, reply: ["ok": true]))
        #expect(page.pushes.isEmpty)
    }

    /// A new document drops the pushes still queued for the old one (the router dropped their envelopes).
    @Test func aNewDocumentDropsQueuedPushes() async {
        let page = FakeChromiumPage()
        page.pushChannel = true
        let bridge = ChromiumPageHostBridge(page: page)
        let gate = AsyncGate()
        page.onCall = { gate.open() }
        bridge.evaluate("slow()")
        bridge.push(envelopes: "[\"old\"]")
        bridge.rebind()
        bridge.push(envelopes: "[\"new\"]")
        await gate.wait()
        let pushed: Bool? = await PageTestWait.value("new push") { done in
            if page.pushes.contains("[\"new\"]") { return done(true) }
            page.onPush = { if page.pushes.contains("[\"new\"]") { done(true) } }
        }
        #expect(pushed == true)
        #expect(!page.pushes.contains("[\"old\"]"))
    }

    // MARK: Page script

    /// The page script's receiver: runs that come before pageClient registers wait for it, in order;
    /// a reply push settles the call's promise.
    @Test func thePageScriptHoldsRunsUntilTheClientListensAndSettlesReplies() throws {
        let context = try #require(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript("""
        var posted = [];
        var __cmuxPageHost = function (text) { posted.push(JSON.parse(text)); };
        var hostReceiver = null;
        Object.defineProperty(this, "cmuxPageListen", { value: function (fn) { hostReceiver = fn; return true; } });
        var setTimeout = function (fn) { fn(); };
        """)
        context.evaluateScript(ChromiumPageHostBridge.pageScript(handlers: []))
        #expect(exception == nil)
        context.evaluateScript("""
        hostReceiver(JSON.stringify([{n: 1}]));
        hostReceiver(JSON.stringify([{n: 2}, {n: 3}]));
        var seen = [];
        var listened = __cmuxPageHostListen(function (envelopes) { for (var e of envelopes) seen.push(e.n); });
        var again = __cmuxPageHostListen(function () {});
        hostReceiver(JSON.stringify([{n: 4}]));
        var settled = null;
        webkit.messageHandlers.cmuxPage.postMessage({op: "ping"}).then(function (r) { settled = r; });
        """)
        #expect(exception == nil)
        #expect(context.evaluateScript("seen.join(',')").toString() == "1,2,3,4")
        #expect(context.evaluateScript("listened").toBool())
        #expect(!context.evaluateScript("again").toBool())
        let seq = context.evaluateScript("posted[0].seq").toInt32()
        let doc = try #require(context.evaluateScript("posted[0].doc").toString())
        context.evaluateScript("hostReceiver(\(ChromiumPageHostWire.jsonString(ChromiumPageHostWire.replyPush(seq: Int(seq), doc: doc, reply: ["ok": true]))))")
        // The promise's continuation runs once the script returns (JavaScriptCore drains microtasks then).
        #expect(context.evaluateScript("settled && settled.ok").toBool())
    }

    /// An old document's reply carries the old token: the new document's call with the same seq stays
    /// pending, and its own reply settles it.
    @Test func aReplyForAnotherDocumentDoesNotSettleTheSameSeq() throws {
        let context = try #require(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript("""
        var posted = [];
        var __cmuxPageHost = function (text) { posted.push(JSON.parse(text)); };
        var hostReceiver = null;
        Object.defineProperty(this, "cmuxPageListen", { value: function (fn) { hostReceiver = fn; return true; } });
        var setTimeout = function (fn) { fn(); };
        """)
        context.evaluateScript(ChromiumPageHostBridge.pageScript(handlers: []))
        context.evaluateScript("""
        var settled = null;
        webkit.messageHandlers.cmuxPage.postMessage({op: "subscribe"}).then(function (r) { settled = r; });
        """)
        #expect(exception == nil)
        let seq = Int(context.evaluateScript("posted[0].seq").toInt32())
        let doc = try #require(context.evaluateScript("posted[0].doc").toString())
        #expect(!doc.isEmpty && doc != "undefined")
        let stale = ChromiumPageHostWire.replyPush(seq: seq, doc: doc + "-old", reply: ["sub": 99])
        context.evaluateScript("hostReceiver(\(ChromiumPageHostWire.jsonString(stale)))")
        #expect(context.evaluateScript("settled === null").toBool(), "a stale document's reply settled the call")
        let own = ChromiumPageHostWire.replyPush(seq: seq, doc: doc, reply: ["sub": 7])
        context.evaluateScript("hostReceiver(\(ChromiumPageHostWire.jsonString(own)))")
        #expect(context.evaluateScript("settled && settled.sub").toInt32() == 7)
        #expect(exception == nil)
    }

    /// The token rides in every replying call and is JSON-escaped in the reply push.
    @Test func theWireCarriesTheDocumentToken() throws {
        let message = try #require(ChromiumPageHostWire.Message(payload: #"{"name":"cmuxPage","seq":3,"doc":"a\"b","body":{}}"#))
        #expect(message.doc == "a\"b")
        #expect(ChromiumPageHostWire.replyPush(seq: 3, doc: "a\"b", reply: nil) == #"{"r":3,"d":"a\"b","v":null}"#)
        #expect(ChromiumPageHostWire.Message(payload: #"{"name":"cmuxPage","seq":3,"body":{}}"#)?.doc == nil)
    }

    /// A frame without `cmuxPageListen` (a child frame, a fork without the channel) gets no push receiver.
    @Test func thePageScriptSkipsTheChannelWithoutTheFork() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var setTimeout = function () {};")
        context.evaluateScript(ChromiumPageHostBridge.pageScript(handlers: []))
        #expect(context.evaluateScript("typeof __cmuxPageHostListen").toString() == "undefined")
        #expect(context.evaluateScript("typeof webkit.messageHandlers.cmuxPage.postMessage").toString() == "function")
    }

    /// Data and script forms of the same run hold the same envelopes.
    @Test func theDataFormIsTheScriptsArgument() {
        let envelopes = [envelope(1), envelope(2)]
        let data = PageRouter.receiveManyData(envelopes)
        #expect(data == "[\(envelope(1).compactText),\(envelope(2).compactText)]")
        #expect(PageRouter.receiveManyScript(data: data) == PageRouter.receiveManyScript(envelopes))
    }
}

/// Opens once; ``wait()`` returns after the first ``open()``.
@MainActor
private final class AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
