import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A failed subagent's, sub-session's or turn's Retry at the relay boundary (the page's frames into
/// ``AgentPaneTransport``, out to acpmux; webviews subagents/retryState.ts `runRetry`, acpmux
/// `_acpmux/retry`). The relay refused the method (`methodRefused`, as -32601), so `runRetry` read
/// it as a daemon without it: a subagent fell back to asking the chat's agent, and a sub-session
/// showed "retry failed". It names the pane's chat (a subagent's, the chat's own turn), which needs
/// no gesture: acpmux retries those on its own, and the click's grant stays for runRetry's fallback
/// send. A sub-session's names the child chat the pane shows only as a card, which takes the click's
/// scope credit like an attach the person makes. Only `sessionId` and `subagentId`.
@Suite(.serialized)
@MainActor
struct AgentPaneRetryRelayTests {
    static func frame(id: Int, params: String) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/retry","params":\#(params)}"#
    }

    @Test func thePaneMaySendRetryInTheShapeRunRetrySends() {
        guard case .send = AcpmuxPaneMethods.decide(Self.frame(id: 1, params: #"{"sessionId":"s","subagentId":"a"}"#),
                                                     isFirst: false, localAppToken: nil) else {
            Issue.record("the relay refused the pane's _acpmux/retry")
            return
        }
        func object(_ params: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(Self.frame(id: 1, params: params).utf8))) as? [String: Any]
        }
        // A subagent of the chat, a sub-session by its own id, the chat's own turn (#25947).
        for params in [#"{"sessionId":"s","subagentId":"a"}"#, #"{"sessionId":"child"}"#] {
            #expect(!AcpmuxPaneMethods.breaksParamsRule(object(params), modeFields: []), "\(params)")
        }
        // `_meta` would carry acpmux's control and trust-gate marks (server/agent_messages.rs).
        for extra in [#""promptId":"p""#, #""_meta":{"acpmux":{"control":"full"}}"#] {
            #expect(AcpmuxPaneMethods.breaksParamsRule(object(#"{"sessionId":"s",\#(extra)}"#), modeFields: []), "\(extra)")
        }
        #expect(AcpmuxPaneMethods.breaksParamsRule(object(#"["s"]"#), modeFields: []))
        // No grant: a fallback send after a daemon without the method still has the click's.
        #expect(!AcpmuxPaneMethods.needsGesture(Self.frame(id: 1, params: #"{"sessionId":"s"}"#), options: AcpmuxPermissionOptions()))
    }

    @Test(.timeLimit(.minutes(1))) func aRetryGoesOutForTheChatAndWithTheClickForItsSubSession() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("_acpmux/retry", with: #"{"promptId":"P~resume-1","kind":"turn"}"#)
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        let sent = { server.peers.first?.frames.filter { $0.contains("_acpmux/retry") } ?? [] }
        func params(_ frame: String) throws -> NSDictionary {
            let object = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
            return try #require(object?["params"] as? [String: Any]) as NSDictionary
        }

        #expect(await transport.send(connection: id, frames: [Self.frame(id: 1, params: #"{"sessionId":"s","promptId":"p"}"#)]) == .intentInvalid,
                "a param the pane never sends")
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 2, params: #"{"sessionId":"child"}"#)]) == .gestureRequired,
                "a chat outside the pane's scope, with no click")
        #expect(sent().isEmpty, "a refused retry reached acpmux: \(sent())")

        // A failed subagent of the pane's chat, and the chat's own turn: no gesture needed.
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 3, params: #"{"sessionId":"s","subagentId":"a"}"#)]) == nil,
                "the relay refused the Retry of the chat's subagent")
        _ = await inbox.frame(containing: #""id":3"#)
        #expect(try sent().map(params) == [["sessionId": "s", "subagentId": "a"] as NSDictionary])

        // A sub-session's Retry names the child chat, which is not the pane's: the click brings it,
        // and leaves its grant for a fallback send.
        transport.gestures.record(click: true)
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 4, params: #"{"sessionId":"child"}"#)]) == nil,
                "the relay refused the Retry of the chat's sub-session")
        _ = await inbox.frame(containing: #""id":4"#)
        #expect(try sent().dropFirst().map(params) == [["sessionId": "child"] as NSDictionary])
        #expect(transport.gestures.isAvailable, "the Retry spent the click's grant")

        // One click brings one chat in: the next outside the scope needs its own.
        #expect(await transport.send(connection: id, frames: [Self.frame(id: 5, params: #"{"sessionId":"other"}"#)]) == .gestureRequired)
        #expect(sent().count == 2, "\(sent())")
    }
}
