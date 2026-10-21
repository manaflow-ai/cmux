import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The reply in place at the relay boundary (the page's frames into ``AgentPaneTransport``, out to
/// acpmux, and acpmux's answer back): `_acpmux/app_reply` goes out only for the pane's own chat,
/// only on a gesture and only in the shape the page sends, and the host mints and sends a reply
/// (``AgentPaneAgentReply/Send``) only when acpmux signed it for that very chat. The page never
/// gets acpmux's signed reply, only what the daemon stored.
@Suite(.serialized)
@MainActor
struct AgentPaneAgentReplyRelayTests {
    /// What the host's ``AgentPaneAgentReply/Send`` was asked to send (the daemon's side).
    @MainActor final class Sent {
        var replies: [AgentPaneAgentReply] = []
    }

    static func reply(id: Int, session: String, extra: String = "") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"_acpmux/app_reply","params":{"sessionId":"\#(session)","to":"child-3","replyTo":"msg_1","threadId":"msg_1","text":"Merged; thanks.","replyId":"m-1"\#(extra)}}"#
    }

    /// acpmux's signed answer, from chat `from`.
    static func signed(from: String) -> String {
        #"{"reply":{"from":"acp:\#(from)","fromName":"Grid fix","to":"acp:child-3","replyTo":"msg_1","threadId":"msg_1","text":"Merged; thanks.","idempotencyKey":"acpmux-reply-k1"}}"#
    }

    static func open(_ server: AcpmuxStandInServer, sent: Sent) async throws -> (AgentPaneTransport, Int, AgentPaneRelayedAllowTests.PageInbox) {
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.sendAgentReply = { reply in
            sent.replies.append(reply)
            return AgentPaneAgentReply.Stored(id: "msg_9", threadId: reply.threadId)
        }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.sessions.add("s")
        return (transport, id, inbox)
    }

    @Test func aReplyGoesOutOnlyAsThePanesChatOnAGestureAndIsSentAsThatChat() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("_acpmux/app_reply", with: Self.signed(from: "s"))
        let sent = Sent()
        let (transport, id, inbox) = try await Self.open(server, sent: sent)
        let relayed = { server.peers.first?.frames.filter { $0.contains("_acpmux/app_reply") } ?? [] }

        #expect(await transport.send(connection: id, frames: [Self.reply(id: 1, session: "s")]) == .gestureRequired)
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.reply(id: 2, session: "other")]) != nil,
                "a chat the pane does not show")
        for extra in [#","recipients":["acp:other"]"#, #","senderName":"Chief""#, #","credential":"c""#] {
            transport.gestures.record()
            #expect(await transport.send(connection: id, frames: [Self.reply(id: 3, session: "s", extra: extra)]) != nil,
                    "a param the page never sends: \(extra)")
        }
        #expect(relayed().isEmpty, "a refused reply reached acpmux: \(relayed())")
        #expect(sent.replies.isEmpty, "a refused reply was sent: \(sent.replies)")

        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.reply(id: 4, session: "s")]) == nil)
        let answer = await inbox.frame(containing: #""id":4"#)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any])
        let message = (object["result"] as? [String: Any])?["agentMessage"] as? [String: Any]
        #expect(message?["id"] as? String == "msg_9", "\(answer)")
        #expect(message?["threadId"] as? String == "msg_1", "\(answer)")
        #expect(!answer.contains("idempotencyKey") && !answer.contains("acp:s"), "acpmux's signed reply reached the page: \(answer)")
        #expect(relayed().count == 1)
        #expect(sent.replies == [AgentPaneAgentReply(session: "s", senderName: "Grid fix", replyTo: "msg_1", threadId: "msg_1",
                                                     text: "Merged; thanks.", idempotencyKey: "acpmux-reply-k1")])
    }

    /// A pane cannot mint a credential for a chat it does not show: acpmux's answer must name the
    /// very chat the frame did, still in the pane's scope.
    @Test func aSignedReplyForAnotherChatSendsNothing() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        server.answer("_acpmux/app_reply", with: Self.signed(from: "other"))
        let sent = Sent()
        let (transport, id, inbox) = try await Self.open(server, sent: sent)
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [Self.reply(id: 5, session: "s")]) == nil)
        let answer = await inbox.frame(containing: #""id":5"#)
        #expect(answer.contains("reply.refused"), "\(answer)")
        #expect(!answer.contains("idempotencyKey"), "\(answer)")
        #expect(sent.replies.isEmpty, "a reply for another chat was sent: \(sent.replies)")

        // No sender wired (a chat on another machine has none): refused, nothing sent.
        server.answer("_acpmux/app_reply", with: Self.signed(from: "s"))
        transport.sendAgentReply = nil
        let reopened = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: reopened, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        transport.gestures.record()
        #expect(await transport.send(connection: reopened, frames: [Self.reply(id: 6, session: "s")]) == nil)
        let unsent = await inbox.frame(containing: #""id":6"#)
        #expect(unsent.contains("reply.daemon_unavailable"), "\(unsent)")
        #expect(sent.replies.isEmpty)
    }
}
