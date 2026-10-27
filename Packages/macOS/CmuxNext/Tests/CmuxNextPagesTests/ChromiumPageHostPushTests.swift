import CmuxNextPagesTestSupport
import CmuxNextSettings
import Foundation
import JavaScriptCore
import Testing
@testable import CmuxNextPages

/// The page push channel (p13-webui-079): with it, the router's envelopes and the replies reach a
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

    /// A main-frame call's reply is a push of `{"r": seq, "v": reply}`; the only DevTools call is the sender check.
    @Test func aReplyOnTheChannelIsAPush() async {
        let page = FakeChromiumPage()
        page.pushChannel = true
        let bridge = ChromiumPageHostBridge(page: page)
        bridge.install { _ in ["ok": true] }
        let reply: String? = await PageTestWait.value("reply") { done in
            page.onPush = { done(page.pushes.last ?? "") }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPage", "seq": 4, "body": ["op": "ping"]]))
        }
        #expect(reply == #"{"r":4,"v":{"ok":true}}"#)
        #expect(page.calls.map { $0.params["expression"] as? String } == ["[location.href, window === window.top]"])
        #expect(bridge.answered == 1)
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
        context.evaluateScript("hostReceiver(\(ChromiumPageHostWire.jsonString(ChromiumPageHostWire.replyPush(seq: Int(seq), reply: ["ok": true]))))")
        // The promise's continuation runs once the script returns (JavaScriptCore drains microtasks then).
        #expect(context.evaluateScript("settled && settled.ok").toBool())
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
