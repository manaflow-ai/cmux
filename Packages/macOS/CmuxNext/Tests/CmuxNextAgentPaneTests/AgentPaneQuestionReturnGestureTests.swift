import Foundation
import CmuxNextPages
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneQuestionReturnGestureTests {
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
}
