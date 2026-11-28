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

    /// The sender asks of `page` so far.
    private static func senderAsks(_ page: FakeChromiumPage) -> Int {
        page.calls.filter { $0.method == "Runtime.evaluate" && $0.params["expression"] as? String == ChromiumPageHostWire.senderExpression }.count
    }

    /// Sends one `cmuxPage` call per seq of `seqs` on `context` and waits until each was answered.
    private static func answerAll(_ page: FakeChromiumPage, _ bridge: ChromiumPageHostBridge, seqs: ClosedRange<Int>, context: Int = 9) async -> Bool {
        let resolves = Set(seqs.map { ChromiumPageHostWire.resolveExpression(seq: $0, reply: ["ok": true]) })
        let answered: Bool? = await PageTestWait.value("\(seqs.count) replies") { done in
            page.onCall = {
                let sent = Set(page.calls.compactMap { $0.params["expression"] as? String }).intersection(resolves)
                if sent.count == resolves.count { done(true) }
            }
            for seq in seqs {
                bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPage", "seq": seq, "body": ["op": "ping"]], context: context))
            }
        }
        return answered == true
    }

    /// cmux#48605: every page call asked its sender of the page first, one DevTools round trip in the
    /// browser's call order per call. A chat page's open makes dozens of calls: now one context is asked once.
    @Test func aContextsSenderIsAskedOnceForAllItsMessages() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        bridge.install { _ in ["ok": true] }
        #expect(await Self.answerAll(page, bridge, seqs: 1...40))
        print("sender-asks: calls=40 asks=\(Self.senderAsks(page))")
        #expect(Self.senderAsks(page) == 1, "40 calls of one context asked its sender \(Self.senderAsks(page)) times")
        // Another context (a reloaded document's) is asked for itself.
        #expect(await Self.answerAll(page, bridge, seqs: 41...45, context: 12))
        #expect(Self.senderAsks(page) == 2)
    }

    /// cmux#48605 (NIGHTLY 2026-11-20 22:03): a sender ask that failed sent the message on with no sender,
    /// so the page's trust check (`PageWebView.receive`) refused it, unanswered and with no reason: the chat
    /// page's handshake and first-paint report never reached the host, and the pane stayed blank until the
    /// loading state gave up and reopened the page in WebKit. A failed ask is asked again, and the calls
    /// behind it go on with their sender once it answers.
    @Test func aSenderAskThatFailsIsAskedAgainAndTheCallsKeepTheirSender() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        var tops: [Bool] = []
        bridge.install { message in
            tops.append(message.isMainFrame && message.frameURL?.absoluteString == page.senderURL)
            return ["ok": true]
        }
        var failures = ChromiumPageHostBridge.senderTries - 1
        page.answer = { method, params in
            guard method == "Runtime.evaluate", params["expression"] as? String == ChromiumPageHostWire.senderExpression,
                  failures > 0 else { return nil }
            failures -= 1
            return #"{"exceptionDetails":{"text":"Cannot find context with specified id"}}"#
        }
        #expect(await Self.answerAll(page, bridge, seqs: 1...3))
        #expect(tops == [true, true, true], "calls behind a failed sender ask lost their sender: \(tops)")
        #expect(Self.senderAsks(page) == ChromiumPageHostBridge.senderTries)
    }

    /// A new document's contexts are its own: a kept sender is forgotten at the commit.
    @Test func aCommitForgetsTheKeptSenders() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        var tops: [Bool] = []
        bridge.install { message in
            tops.append(message.isMainFrame)
            return ["ok": true]
        }
        #expect(await Self.answerAll(page, bridge, seqs: 1...2))
        bridge.documentCommitted()
        // Were the kept answer used, this call would carry the top frame without asking.
        page.senderIsTop = false
        #expect(await Self.answerAll(page, bridge, seqs: 3...3))
        #expect(Self.senderAsks(page) == 2, "the context's sender was not asked again after the commit")
        #expect(tops == [true, true, false], "a call after the commit kept the old document's answer: \(tops)")
    }

    /// Review of cmux#48605: a new renderer numbers its contexts again, and some commits (an `about:` one, one
    /// the navigation policy sends back) never reach `documentCommitted()`. A frame's navigation in the DevTools
    /// stream, which is ordered with the binding calls, forgets every kept sender, so a reused number is asked anew.
    @Test func aFrameNavigationInTheStreamForgetsTheKeptSenders() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        var tops: [Bool] = []
        bridge.install { message in
            tops.append(message.isMainFrame)
            return ["ok": true]
        }
        #expect(await Self.answerAll(page, bridge, seqs: 1...1))
        #expect(!bridge.receive(devToolsMessage: #"{"method":"Page.frameNavigated","params":{"frame":{"id":"F","url":"about:blank"}}}"#))
        page.senderIsTop = false
        #expect(await Self.answerAll(page, bridge, seqs: 2...2))
        #expect(Self.senderAsks(page) == 2, "a context number reused after a navigation kept the old document's sender")
        #expect(tops == [true, false])
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
            // The main frame's own context: a context's sender is kept, so the child's answer stays the child's.
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPagePainted", "body": 12], context: 10))
        }
        #expect(fromMain == "cmuxPagePainted 12")
        #expect(reached == 1)
    }

    /// Typing under load 2026-11-22: a sender check that failed once under full CPU load made the main
    /// frame's input readiness look like a subframe's, and it was dropped, so every typed key stayed held.
    /// The check is tried again, and the message arrives as the main frame's.
    @Test func aSenderCheckThatFailsOnceIsTriedAgain() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: [PageInputReadiness.handlerName])
        var checks = 0
        page.answer = { method, params in
            guard method == "Runtime.evaluate", params["expression"] as? String == "[location.href, window === window.top]" else { return nil }
            checks += 1
            return checks == 1 ? #"{"result":{}}"# : nil
        }
        let arrived: String? = await PageTestWait.value("readiness") { done in
            bridge.onMessage = { name, body in done("\(name) \(body)") }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": PageInputReadiness.handlerName, "body": 1]))
        }
        #expect(arrived == "\(PageInputReadiness.handlerName) 1")
        #expect(checks == 2)
        #expect(bridge.unknownSenders == 0)

        // A call with a reply too: its handler sees the main frame's URL.
        checks = 0
        var received: PageHostMessage?
        bridge.install { message in
            received = message
            return nil
        }
        let resolve = ChromiumPageHostWire.resolveExpression(seq: 3, reply: nil)
        let replied: Bool? = await PageTestWait.value("reply") { done in
            page.onCall = { if page.calls.contains(where: { $0.params["expression"] as? String == resolve }) { done(true) } }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPage", "seq": 3, "body": ["op": "ping"]]))
        }
        #expect(replied == true)
        #expect(received?.isMainFrame == true)
        #expect(received?.frameURL?.absoluteString == page.senderURL)
    }

    /// A sender that never answers the check is not taken for a subframe: its message is dropped (and
    /// counted), a fire-and-forget one never reaches ``ChromiumPageHostBridge/onMessage`` and a call's
    /// handler never runs, but the call's promise settles with null.
    @Test func aSenderThatNeverAnswersIsDroppedNotTakenForASubframe() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: [PageInputReadiness.handlerName])
        page.answer = { method, params in
            method == "Runtime.evaluate" && params["expression"] as? String == "[location.href, window === window.top]"
                ? #"{"exceptionDetails":{"text":"context gone"}}"# : nil
        }
        var handled: [Bool] = []
        bridge.install { message in
            handled.append(message.isMainFrame)
            return nil
        }
        bridge.onMessage = { _, _ in handled.append(false) }
        let tries = ChromiumPageHostBridge.senderTries
        let checks = { page.calls.filter { $0.params["expression"] as? String == "[location.href, window === window.top]" }.count }
        let tried: Bool? = await PageTestWait.value("readiness checks") { done in
            page.onCall = { if checks() == tries { done(true) } }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": PageInputReadiness.handlerName, "body": 1]))
        }
        #expect(tried == true)
        let resolve = ChromiumPageHostWire.resolveExpression(seq: 4, reply: nil)
        let settled: Bool? = await PageTestWait.value("call settles") { done in
            page.onCall = { if page.calls.contains(where: { $0.params["expression"] as? String == resolve }) { done(true) } }
            bridge.receive(devToolsMessage: FakeChromiumPage.bindingCall(["name": "cmuxPage", "seq": 4, "body": ["op": "ping"]]))
        }
        #expect(settled == true)
        #expect(handled.isEmpty)
        #expect(checks() == 2 * tries)
        #expect(bridge.unknownSenders == 2)
        #expect(bridge.answered == 0)
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

    /// RFD 0062: V8 compiles and keeps every distinct script text, so a steady push of new data is one
    /// fixed function called with the data as its argument, never a new `Runtime.evaluate` text. The
    /// pushes queued together go in one call, in order with the scripts around them.
    @Test func steadyPushesCallOneFixedFunctionWithTheirData() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        let done: Bool? = await PageTestWait.value("pushes") { done in
            page.onCall = {
                if page.calls.contains(where: { ($0.params["expression"] as? String) == "after()" }) { done(true) }
            }
            bridge.evaluate("before()")
            for index in 0..<20 { bridge.receive(#"{"seq":\#(index)}"#) }
            bridge.evaluate("after()")
        }
        #expect(done == true)
        let calls = page.calls.filter { $0.method == "Runtime.callFunctionOn" }
        let declarations = Set(calls.compactMap { $0.params["functionDeclaration"] as? String })
        #expect(declarations == [ChromiumPageHostBridge.callDeclaration(body: PageRouter.receiveBody, argument: "envelope")])
        #expect(calls.allSatisfy { $0.params["objectId"] as? String == "global-1" })
        let texts = calls.flatMap { (($0.params["arguments"] as? [[String: any Sendable]])?.first?["value"] as? [String]) ?? [] }
        #expect(texts == (0..<20).map { #"{"seq":\#($0)}"# })
        let order = page.calls.compactMap { call -> String? in
            call.method == "Runtime.callFunctionOn" ? "push" : (call.params["expression"] as? String).flatMap { $0 == "globalThis" ? nil : $0 }
        }
        #expect(order.first == "before()" && order.last == "after()" && order.dropFirst().dropLast().allSatisfy { $0 == "push" })
        let evaluated = page.calls.compactMap { $0.params["expression"] as? String }
        #expect(!evaluated.contains { $0.contains("seq") }, "a push went as a new script text")
    }

    /// The call's function runs `body` once per text, in order, and one that throws does not stop the rest.
    @Test func theCallDeclarationRunsEachTextInTurn() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var got = []; var fn = " + ChromiumPageHostBridge.callDeclaration(
            body: "if (data === 'b') throw new Error('b'); got.push(data);", argument: "data"))
        context.evaluateScript("console = { error() {} }; fn(['a', 'b', 'c'])")
        #expect(context.evaluateScript("got.join(',')")?.toString() == "a,c")
    }

    /// A new document drops the kept `globalThis` handle: the next push asks for it again.
    @Test func aCommittedDocumentAsksForTheGlobalHandleAgain() async {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        func pushAndWait(_ count: Int) async {
            _ = await PageTestWait.value("push \(count)") { done in
                page.onCall = {
                    if page.calls.filter({ $0.method == "Runtime.callFunctionOn" }).count == count { done(true) }
                }
                bridge.evaluate("x", argument: "data", text: "\(count)")
            }
        }
        await pushAndWait(1)
        await pushAndWait(2)
        #expect(page.calls.filter { $0.params["expression"] as? String == "globalThis" }.count == 1)
        bridge.documentCommitted()
        await pushAndWait(3)
        #expect(page.calls.filter { $0.params["expression"] as? String == "globalThis" }.count == 2)
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

    // MARK: Runtime domain around navigations

    /// The methods of the calls `act` makes the page get, once there are `count` of them.
    private func calls(_ page: FakeChromiumPage, count: Int, _ act: () -> Void) async -> [String]? {
        let before = page.calls.count
        return await PageTestWait.value("\(count) calls") { done in
            page.onCall = { if page.calls.count == before + count { done(page.calls[before...].map(\.method)) } }
            act()
        }
    }

    /// The setup sends every call, in order, before it awaits the first answer: they come back in
    /// about one round trip, not one each (one at a time took about 50 ms on the chat page).
    @Test func setUpSendsEveryCallBeforeAwaitingTheFirstAnswer() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        let scripts = ["one()", "two()"]
        try await bridge.setUp(documentScripts: scripts)
        let expected = ChromiumPageHostBridge.setupCalls(handlers: ["cmuxPagePainted"], documentScripts: scripts)
        #expect(page.calls.map(\.method) == expected.map(\.0))
        #expect(Array(page.calls.compactMap { $0.params["source"] as? String }.suffix(2)) == scripts)
        #expect(page.sentBeforeFirstAwait == expected.count)
        #expect(bridge.runtimeEnabled)
    }

    /// The setup leaves the Runtime domain on for the first document; its commit turns it off and adds
    /// the binding again. Measured (headless Chromium 157, cold, n=12): the chat page's modules evaluated
    /// in 116 ms with the domain on and 44 ms with it off from the commit, and the binding was there at
    /// document start either way.
    @Test func theFirstDocumentsCommitTurnsTheRuntimeDomainOff() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page, fireAndForget: ["cmuxPagePainted"])
        try await bridge.setUp(documentScripts: ["one()"])
        #expect(page.calls.map(\.method) == ChromiumPageHostBridge.setupCalls(handlers: ["cmuxPagePainted"], documentScripts: ["one()"]).map(\.0))
        #expect(bridge.runtimeEnabled)
        let sent = await calls(page, count: 2) { bridge.documentCommitted() }
        #expect(sent == ["Runtime.disable", "Runtime.addBinding"])
        #expect(page.calls.last?.params["name"] as? String == ChromiumPageHostBridge.bindingName)
        #expect(!bridge.runtimeEnabled)
    }

    @Test func aCommitCanResendInputReadinessAfterReaddingTheBinding() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        try await bridge.setUp(documentScripts: [])
        let sent = await calls(page, count: 3) { bridge.documentCommitted(resendInputReadiness: true) }
        #expect(sent == ["Runtime.disable", "Runtime.addBinding", "Runtime.evaluate"])
        #expect(page.calls.last?.params["expression"] as? String == "globalThis.__cmuxInputReadyResend?.();")
    }

    /// A reload and a navigation the app starts each turn the Runtime domain on (and add the binding,
    /// which `Runtime.disable` dropped) before the page navigates, and their commits turn it off again:
    /// every navigation follows enable, navigate, commit, disable. Measured: with the domain off at a
    /// reload the binding never reached the new document; turned on (with the binding) before the reload,
    /// it was there at document start and the reload evaluated as fast as before (39 ms).
    @Test func everyNavigationTurnsTheRuntimeDomainOnFirstAndItsCommitTurnsItOff() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        try await bridge.setUp(documentScripts: [])
        var sequence: [String] = []
        page.onCall = {
            guard let method = page.calls.last?.method, ["Runtime.enable", "Runtime.disable", "Runtime.addBinding"].contains(method) else { return }
            sequence.append(method)
        }
        page.onNavigate = { sequence.append("navigate") }
        let url = URL(string: "cmux-page://test.plain/index.html")!

        // First load: the setup turned the domain on, so it loads at once.
        bridge.navigate { page.load(url) }
        #expect(sequence == ["navigate"])
        await committed(bridge, page, sequence: { sequence })

        // Reload.
        let reloaded: Bool? = await PageTestWait.value("reload") { done in
            page.onNavigate = { sequence.append("navigate"); done(true) }
            bridge.navigate { page.reload() }
        }
        #expect(reloaded == true)
        await committed(bridge, page, sequence: { sequence })

        // Navigation to another document of the page.
        let navigated: Bool? = await PageTestWait.value("navigation") { done in
            page.onNavigate = { sequence.append("navigate"); done(true) }
            bridge.navigate { page.load(url.appending(path: "other.html")) }
        }
        #expect(navigated == true)
        await committed(bridge, page, sequence: { sequence })

        let turn = ["Runtime.disable", "Runtime.addBinding"]
        let start = ["Runtime.enable", "Runtime.addBinding", "navigate"]
        #expect(sequence == ["navigate"] + turn + start + turn + start + turn)
        #expect(page.reloads == 1)
        #expect(page.loaded.count == 2)
    }

    /// Commits the document and waits until its calls went out.
    private func committed(_ bridge: ChromiumPageHostBridge, _ page: FakeChromiumPage, sequence: @escaping () -> [String]) async {
        let count = sequence().count
        let done: Bool? = await PageTestWait.value("commit") { done in
            let previous = page.onCall
            page.onCall = {
                previous?()
                if sequence().count == count + 2 { done(true) }
            }
            bridge.documentCommitted()
        }
        #expect(done == true)
        #expect(!bridge.runtimeEnabled)
    }

    /// Two navigations asked for while the domain turns on run in the order asked, both after it is on.
    @Test func navigationsAskedWhileTheDomainTurnsOnRunInOrder() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        try await bridge.setUp(documentScripts: [])
        bridge.documentCommitted()
        var order: [String] = []
        let ran: [String]? = await PageTestWait.value("navigations") { done in
            bridge.navigate {
                order.append("first after \(page.calls.filter { $0.method == "Runtime.enable" }.count) enables")
            }
            bridge.navigate {
                order.append("second")
                done(order)
            }
        }
        #expect(ran == ["first after 2 enables", "second"])
        #expect(bridge.runtimeEnabled)
    }

    /// A document the page navigated to by itself (the domain was off: no `navigate` turned it on)
    /// still gets the binding with its commit, and no `Runtime.disable` is sent for it. Measured:
    /// `Runtime.addBinding` with the domain off put the binding in the new document 18 ms after its
    /// navigation started, and calls from it arrived (12/12).
    @Test func aDocumentThePageOpenedItselfGetsTheBindingWithItsCommit() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        try await bridge.setUp(documentScripts: [])
        #expect(await calls(page, count: 2) { bridge.documentCommitted() } == ["Runtime.disable", "Runtime.addBinding"])
        // The page's own navigation commits: the domain is off already.
        #expect(await calls(page, count: 1) { bridge.documentCommitted() } == ["Runtime.addBinding"])
        #expect(page.calls.last?.params["name"] as? String == ChromiumPageHostBridge.bindingName)
        #expect(!bridge.runtimeEnabled)
    }

    /// After the renderer ended, a navigation (the crash path's reload) runs at once: a DevTools call
    /// would wait for the renderer that only this navigation brings.
    @Test func aNavigationAfterTheRendererEndedDoesNotWaitForIt() async throws {
        let page = FakeChromiumPage()
        let bridge = ChromiumPageHostBridge(page: page)
        try await bridge.setUp(documentScripts: [])
        #expect(await calls(page, count: 2) { bridge.documentCommitted() } != nil)
        bridge.rendererEnded()
        let before = page.calls.count
        var ran = false
        bridge.navigate { ran = true }
        #expect(ran)
        #expect(page.calls.count == before, "no Runtime call waits on the gone renderer")
        // The new renderer's document commits: the binding comes with it, and the next navigation
        // turns the domain on first again.
        #expect(await calls(page, count: 1) { bridge.documentCommitted() } == ["Runtime.addBinding"])
        let next: [String]? = await PageTestWait.value("navigation") { done in
            bridge.navigate { done(Array(page.calls[(before + 1)...].map(\.method))) }
        }
        #expect(next == ["Runtime.enable", "Runtime.addBinding"])
    }

    // MARK: Page script queue

    /// The page script's queue against a binding that appears late: the 400 retries (2 s) run out with
    /// messages queued, and a later send starts them again, so every message goes out once the binding
    /// exists. Before, only a send that found the queue empty restarted the retries, so once they ran
    /// out every later message waited for good.
    @Test func aSendAfterTheRetriesRanOutStartsThemAgain() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var timers = [];
        globalThis.setTimeout = (callback) => { timers.push(callback); return timers.length; };
        // Runs every timer pending now and those they set, up to `limit`.
        var runTimers = (limit) => { let ran = 0; while (timers.length && ran < limit) { timers.shift()(); ran += 1; } return ran; };
        var sent = [];
        """)
        context.evaluateScript(ChromiumPageHostBridge.pageScript(handlers: ["cmuxPagePainted"]))
        let post = "globalThis.webkit.messageHandlers.cmuxPagePainted.postMessage"
        context.evaluateScript("\(post)(1); \(post)(2);")
        #expect(context.evaluateScript("timers.length").toInt32() == 1, "one retry pending for both sends")
        #expect(context.evaluateScript("runTimers(1000)").toInt32() == 400, "the retries run out after 400")
        #expect(context.evaluateScript("timers.length").toInt32() == 0)
        // A third and a fourth send, still with no binding: the retries start again, once.
        context.evaluateScript("\(post)(3); \(post)(4);")
        #expect(context.evaluateScript("timers.length").toInt32() == 1)
        // The binding appears: the next retry sends everything, in order.
        context.evaluateScript("globalThis.\(ChromiumPageHostBridge.bindingName) = (text) => sent.push(JSON.parse(text).body);")
        context.evaluateScript("runTimers(1000)")
        #expect(context.evaluateScript("sent.join(',')").toString() == "1,2,3,4")
        #expect(context.evaluateScript("timers.length").toInt32() == 0, "no retry left once the queue is empty")
        // With the binding there, a send goes out at once and sets no timer.
        context.evaluateScript("\(post)(5)")
        #expect(context.evaluateScript("sent.join(',')").toString() == "1,2,3,4,5")
        #expect(context.evaluateScript("timers.length").toInt32() == 0)
    }

    /// A message sent while the binding exists goes out at once, before any queued retry, and the
    /// retry that finds the queue empty stops.
    @Test func aBindingThatAppearsBetweenRetriesTakesTheQueueAtTheNextSend() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var timers = [];
        globalThis.setTimeout = (callback) => { timers.push(callback); return timers.length; };
        var sent = [];
        """)
        context.evaluateScript(ChromiumPageHostBridge.pageScript(handlers: ["cmuxPagePainted"]))
        let post = "globalThis.webkit.messageHandlers.cmuxPagePainted.postMessage"
        context.evaluateScript("\(post)(1)")
        context.evaluateScript("globalThis.\(ChromiumPageHostBridge.bindingName) = (text) => sent.push(JSON.parse(text).body);")
        context.evaluateScript("\(post)(2)")
        #expect(context.evaluateScript("sent.join(',')").toString() == "1,2")
        context.evaluateScript("timers.shift()()")
        #expect(context.evaluateScript("timers.length").toInt32() == 0)
    }
}
