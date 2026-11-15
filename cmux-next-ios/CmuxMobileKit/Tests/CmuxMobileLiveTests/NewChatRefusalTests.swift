import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A Claude chat its Mac started refuses a send from a phone of another account (acpmux D13,
/// `remote.local_claude_session`, `action: new_chat`). Leo, 2026-11-14, on his iPhone, of the
/// sentence that refusal used to show ("From another device, start a new chat there. On this Mac
/// itself, close and reopen the chat"): "wtf do i do these options dont do anything"; and then:
/// "Where a refusal stays (another account), name the one action that works, as a button." The
/// chat says ``AgentChatStore/newChatNotice``, which the composer draws with New chat, never
/// acpmux's words; the draft comes back for the new chat.
@MainActor
@Suite struct NewChatRefusalTests {
    nonisolated static let refusalMessage =
        "Only the cmux app on this Mac can control a Claude chat started on this Mac. From another device, start a new chat there. On this Mac itself, close and reopen the chat to reconnect."

    nonisolated static func link() -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize":
                return [reply(#"{"protocolVersion":1,"_meta":{"acpmux":{"fullAccess":true}}}"#)]
            case "_acpmux/watch":
                return [reply(#"{"sessions":[{"sessionId":"s1","name":"lane","harness":"claude","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                return [reply(#"{"session":{"sessionId":"s1","status":"idle","pending":[]},"hasMore":false,"lastSeq":0,"events":[]}"#)]
            case "session/prompt":
                // acpmux's D13 refusal for a client that is not the owner's own paired phone
                // (hub/web_control.rs local_claude_refusal).
                return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"\#(refusalMessage)","data":{"reason":"remote.local_claude_session","harness":"claude","action":"new_chat"}}}"#.utf8)]
            default:
                return [reply("{}")]
            }
        }
    }

    @Test func theRefusalNamesNewChatNotAcpmuxWords() {
        typealias RPC = AcpmuxConnection.RPCError
        let full = RPC(code: -32000, message: Self.refusalMessage, reason: "remote.local_claude_session", action: "new_chat")
        #expect(AcpmuxSessionSource.message(full) == AgentChatStore.newChatNotice)
        // acpmux's action alone names the way out; an older Mac's refusal has only the reason.
        #expect(AcpmuxSessionSource.message(RPC(code: -32000, message: "x", reason: nil, action: "new_chat"))
            == AgentChatStore.newChatNotice)
        #expect(AcpmuxSessionSource.message(RPC(code: -32000, message: Self.refusalMessage, reason: "remote.local_claude_session"))
            == AgentChatStore.newChatNotice)
        #expect(!AgentChatStore.newChatNotice.contains("close and reopen"))
        // Another refusal keeps its own copy.
        #expect(AcpmuxSessionSource.message(RPC(code: -32000, message: "x", reason: "trust.pending")) != AgentChatStore.newChatNotice)
    }

    @Test func aRefusedSendComesBackWithTheNewChatNotice() async throws {
        let link = Self.link()
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        defer { withExtendedLifetime(hub) {} }
        let summary = AgentSessionSummary(id: "s1", name: "lane", harness: "claude", agentName: "Claude",
                                          cwd: "/tmp/w", workspaceTitle: "w", macName: "mini")
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: summary))
        for _ in 0..<200 { await Task.yield() }
        store.send(prompt: "hello")
        for _ in 0..<2000 where store.returnedDraft == nil { await Task.yield() }
        #expect(store.clientError == AgentChatStore.newChatNotice)
        #expect(store.returnedDraft?.text == "hello", "the words come back for the new chat")
    }
}
