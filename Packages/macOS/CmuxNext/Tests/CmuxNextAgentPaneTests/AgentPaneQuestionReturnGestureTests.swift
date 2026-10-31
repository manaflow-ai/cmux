import CmuxNextTestSupport
import Foundation
import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Testing
@testable import CmuxNextAgentPane

@MainActor @Suite(.closesItsWindows)
struct AgentPaneQuestionReturnGestureTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func anUnchangedOwnerBindingReinstallsAfterChromiumInvalidatesItsContext() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let source = try #require(AgentPageTestRoot.page)
        let hosting = FakeChromiumHosting()
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "s"),
                                             source: .bundled(source), pageHost: true, chromium: hosting))
        let page = try #require(view.page)
        await page.chromiumStart?.value
        let chromium = try #require(hosting.made.first)
        let window = NSWindow(contentRect: view.bounds, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.close(); window.close() }
        _ = try await view.model.transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        let pending = try #require(try JSONSerialization.jsonObject(
            with: Data(AgentPaneRelayedAllowTests.pendingQuestion().utf8)) as? [String: Any])
        view.model.transport.decisions.observe(pending, replyTo: nil)
        let targets = [PageQuestionKeyTarget(sessionID: "s", permissionID: "p1")]
        view.refreshQuestionKeyBinding()
        let cached = try #require(view.questionKeyBinding)
        #expect(page.hasQuestionKeyTargets(targets))
        // Navigation invalidates the channel independently of the native pending collection.
        chromium.onEvent?(.devTools(#"{"method":"Runtime.executionContextsCleared"}"#))
        #expect(!page.hasQuestionKeyTargets(targets))
        #expect(view.questionKeyBinding == cached)
        view.refreshQuestionKeyBinding()
        #expect(page.hasQuestionKeyTargets(targets), "the owner's unchanged cache prevented a new installation")
        #expect(view.questionKeyBinding == cached)
    }

    @Test func pageVisibilityRevokesTheOwnersCachedBindingAndRequiresANewReturn() throws {
        let source = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "s"),
                                             source: .bundled(source), pageHost: true, chromium: nil))
        defer { view.close() }
        let page = try #require(view.page)
        view.questionKeyBinding = AgentPaneView.QuestionKeyBinding(connection: 1, session: "s", contexts: [:])
        view.model.transport.gestures.recordQuestionReturn(true)
        let beforeHide = try #require(view.model.transport.gestures.questionReturnWitness)
        // Invoke the descendant first, before AgentPaneView's ancestor hook: this is the order
        // that previously left the owner's cache populated after the channel was invalidated.
        page.viewDidHide()
        #expect(view.questionKeyBinding == nil)
        #expect(!view.model.transport.gestures.consumeQuestionReturn(beforeHide))
        page.viewDidUnhide()
        #expect(view.model.transport.gestures.questionReturnWitness == nil)
        view.model.transport.gestures.recordQuestionReturn(true)
        let beforeDetach = try #require(view.model.transport.gestures.questionReturnWitness)
        page.removeFromSuperview()
        #expect(!view.model.transport.gestures.consumeQuestionReturn(beforeDetach))
        view.addSubview(page)
        #expect(view.model.transport.gestures.questionReturnWitness == nil)
    }

    @Test func decisionsBeforeRequestsLeaveTombstonesAndOlderDecisionsKeepNewerQuestions() throws {
        let contexts = AcpmuxDecisionContexts()
        var pending = try #require(try JSONSerialization.jsonObject(with: Data(AgentPaneRelayedAllowTests.pendingQuestion().utf8)) as? [String: Any])
        var params = try #require(pending["params"] as? [String: Any])
        let decision: [String: Any] = ["method": "_acpmux/event", "params": [
            "dir": "mux", "kind": "permission_decision", "sessionId": "s", "seq": 20,
            "msg": ["permissionId": "p1"],
        ]]
        contexts.observe(decision, replyTo: nil)
        params["seq"] = 10
        pending["params"] = params
        contexts.observe(pending, replyTo: nil)
        #expect(contexts.questions(session: "s").isEmpty)
        params["seq"] = 30
        pending["params"] = params
        contexts.observe(pending, replyTo: nil)
        #expect(contexts.questions(session: "s").count == 1)
        let version = contexts.pendingQuestionVersion()
        contexts.observe(pending, replyTo: nil)
        contexts.observe(decision, replyTo: nil)
        #expect(contexts.questions(session: "s").count == 1)
        #expect(contexts.pendingQuestionVersion() == version)
    }

    @Test func aReturnTicketSendsItsExactAnswerOnlyAfterDOMRedemptionAndCannotReplay() async throws {
        typealias Allow = AgentPaneRelayedAllowTests
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("initialize", with: #"{"protocolVersion":1,"_meta":{"acpmux":{"origin":"local","personInstance":"\#(Allow.instance)"}}}"#)
        let inbox = Allow.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let connection = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: connection, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#])
        _ = await inbox.frame(containing: #""origin":"local""#)
        transport.sessions.add("s")
        server.push(Allow.pendingQuestion(), to: 0)
        _ = await inbox.frame(containing: "permission_pending")
        let intent = try #require(Allow.intent(option: "yes", answers: ["q1": "My answer"]))
        let context = try #require(transport.decisions.context(session: "s", permission: "p1"))
        transport.gestures.recordQuestionReturn(true)
        let rejectedWitness = try #require(transport.gestures.questionReturnWitness)
        transport.offerQuestionKeyCredit(target: PageQuestionKeyTarget(sessionID: "s", permissionID: "p1"),
                                         intent: intent, context: context, connection: connection, witness: rejectedWitness) { false }
        let rejectedTicket = try #require(transport.reserveGesture(intent))
        let rejectedAnswer = #"{"jsonrpc":"2.0","id":6,"method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"yes","answers":{"q1":"My answer"},"_meta":{"cmuxGesture":"\#(rejectedTicket)"}}}"#
        #expect(await transport.send(connection: connection, frames: [rejectedAnswer]) == .gestureRequired)
        #expect(server.peers.first?.frames.contains { $0.contains("permission_respond") } == false)
        transport.gestures.record()
        transport.gestures.recordQuestionReturn(true)
        let witness = try #require(transport.gestures.questionReturnWitness)
        var redeemed = 0
        transport.offerQuestionKeyCredit(target: PageQuestionKeyTarget(sessionID: "s", permissionID: "p1"),
                                         intent: intent, context: context, connection: connection, witness: witness) {
            redeemed += 1
            return true
        }
        let ticket = try #require(transport.reserveGesture(intent))
        let answer = #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"yes","answers":{"q1":"My answer"},"_meta":{"cmuxGesture":"\#(ticket)"}}}"#
        #expect(await transport.send(connection: connection, frames: [answer]) == nil)
        _ = await inbox.frame(containing: #""id":7"#)
        #expect(redeemed == 1)
        #expect(!transport.gestures.consumeForSend())
        #expect(await transport.send(connection: connection, frames: [answer]) == .gestureRequired)
        let responses = server.peers.first?.frames.filter { $0.contains("permission_respond") } ?? []
        #expect(responses.count == 1)
        #expect(responses.first?.contains("My answer") == true)
    }

    @Test func aReturnWitnessIsSingleUseAndCannotSpendAnOrdinaryPermissionClick() throws {
        let gestures = AgentPaneUserGestures()
        gestures.record()
        gestures.recordQuestionReturn(true)
        let witness = try #require(gestures.questionReturnWitness)
        #expect(!gestures.hasFreshAnswerGesture)
        #expect(!AcpmuxPaneMethods.answerAllowed("_acpmux/permission_respond", gestures))
        #expect(gestures.consumeQuestionReturn(witness))
        #expect(!gestures.consumeQuestionReturn(witness))
        #expect(!gestures.consumeForSend())
    }

    @Test func nativeReturnRepliesAreAnnouncedBeforeLocalAndDaemonRefusals() async throws {
        typealias Allow = AgentPaneRelayedAllowTests
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("initialize", with: #"{"protocolVersion":1,"_meta":{"acpmux":{"origin":"local","personInstance":"\#(Allow.instance)"}}}"#)
        server.refuse("_acpmux/permission_respond", with: #"{"code":-32000,"message":"approve this on the Mac app","data":{"reason":"permission.person_required"}}"#)
        let inbox = Allow.PageInbox()
        let transport = AgentPaneTransport()
        defer { transport.close(connection: transport.current) }
        var delivered: [[String: Any]] = []
        transport.deliver = { event, done in
            delivered += event.frames.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            inbox.deliver(event.frames)
            done()
        }
        let connection = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: connection, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#])
        _ = await inbox.frame(containing: #""origin":"local""#)
        transport.sessions.add("s")
        server.push(Allow.pendingQuestion(), to: 0)
        _ = await inbox.frame(containing: "permission_pending")
        let target = PageQuestionKeyTarget(sessionID: "s", permissionID: "p1")
        let method = "_acpmux/permission_respond"

        // A real Other answer can exceed the relay's per-string limit. The card did not run
        // onReply, but still needs the host's error and a fresh attempt rather than silence.
        let tooLong: [String: Any] = ["jsonrpc": "2.0", "id": "question-key-too-long", "method": method, "params": [
            "sessionId": "s", "permissionId": "p1", "optionId": "yes",
            "answers": ["q1": String(repeating: "x", count: AcpmuxPaneMethods.maximumAnswerBytes + 1)],
        ]]
        transport.submitQuestionKeyReply(connection: connection, requestID: "question-key-too-long", target: target,
                                         frame: try #require(AcpmuxRequestIds.encode(tooLong)))
        _ = await inbox.frame(containing: "transport.intent_invalid")
        #expect(server.peers.first?.frames.contains { $0.contains("permission_respond") } == false)

        let intent = try #require(Allow.intent(option: "yes", answers: ["q1": "My answer"]))
        let context = try #require(transport.decisions.context(session: "s", permission: "p1"))
        transport.gestures.recordQuestionReturn(true)
        let witness = try #require(transport.gestures.questionReturnWitness)
        transport.offerQuestionKeyCredit(target: target, intent: intent, context: context, connection: connection, witness: witness) { true }
        let ticket = try #require(transport.reserveGesture(intent))
        let retry = #"{"jsonrpc":"2.0","id":"question-key-retry","method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"yes","answers":{"q1":"My answer"},"_meta":{"cmuxGesture":"\#(ticket)"}}}"#
        transport.submitQuestionKeyReply(connection: connection, requestID: "question-key-retry", target: target, frame: retry)
        _ = await inbox.frame(containing: "permission.person_required")
        for requestID in ["question-key-too-long", "question-key-retry"] {
            let announced = try #require(delivered.firstIndex { ($0["params"] as? [String: Any])?["id"] as? String == requestID })
            let answered = try #require(delivered.firstIndex { $0["id"] as? String == requestID && $0["error"] != nil })
            #expect(announced < answered)
            let params = try #require(delivered[announced]["params"] as? [String: Any])
            #expect(delivered[announced]["method"] as? String == "_cmux/question_key_request")
            #expect(params["sessionId"] as? String == "s")
            #expect(params["permissionId"] as? String == "p1")
        }
    }

    @Test func newerInputRevokesTheOriginalReturnWitness() throws {
        let gestures = AgentPaneUserGestures()
        gestures.recordQuestionReturn(true)
        let first = try #require(gestures.questionReturnWitness)
        gestures.recordQuestionReturn(false)
        #expect(!gestures.consumeQuestionReturn(first))
        gestures.recordQuestionReturn(true)
        let second = try #require(gestures.questionReturnWitness)
        gestures.record()
        #expect(!gestures.consumeQuestionReturn(second))
    }

    @Test func anOrdinaryGrantAndAQuestionReturnCannotBothSpendOneGesture() throws {
        let gestures = AgentPaneUserGestures()

        // The ordinary granting path wins first (as a queued prompt or a
        // reserved ticket can), so the pending Chromium answer loses its key.
        gestures.record()
        gestures.recordQuestionReturn(true)
        let ordinaryFirst = try #require(gestures.questionReturnWitness)
        #expect(gestures.consume())
        #expect(!gestures.consumeQuestionReturn(ordinaryFirst))

        // If Chromium redeems first, it clears the ordinary grant as well.
        gestures.record()
        gestures.recordQuestionReturn(true)
        let questionFirst = try #require(gestures.questionReturnWitness)
        #expect(gestures.consumeQuestionReturn(questionFirst))
        #expect(!gestures.consume())
    }

    @Test func aSameIDQuestionReissueDoesNotMatchTheOldBindingContext() {
        let old = AcpmuxDecisionContexts.Context(nonce: String(repeating: "a", count: 64),
                                                 instance: String(repeating: "b", count: 32))
        let reissued = AcpmuxDecisionContexts.Context(nonce: String(repeating: "c", count: 64),
                                                      instance: String(repeating: "d", count: 32))
        #expect(old != reissued, "same permission IDs must still carry a distinct decision context")
    }
}
