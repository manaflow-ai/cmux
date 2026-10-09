import Foundation
import Synchronization
import Testing
@testable import CmuxNextAgentPane

/// ``RemoteAcpmuxWire``: the page's acpmux JSON-RPC answered by typed calls on the owning
/// session daemon. Only the chat's own session is served; prompts are text only; nothing that
/// starts a session, sets a mode or reads a folder reaches the other machine; daemon pushes
/// become acpmux notifications; the attachment's end closes the wire so the page reconnects.
@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxWireTests {
    /// A scripted daemon side that records every call.
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let calls = Mutex<[String]>([])
        let handler = Mutex<(@Sendable (AgentSessionRemoteEvent) -> Void)?>(nil)
        let prompts = Mutex<[(String, String)]>([])

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            calls.withLock { $0.append("attach:\(page.limit ?? 0)") }
            self.handler.withLock { $0 = handler }
            return Data(#"{"session":{"sessionId":"acp_1","name":"sub","status":"running"},"events":[{"seq":3}],"hasMore":false,"lastSeq":3}"#.utf8)
        }
        func events(_ page: AgentSessionPage) async throws -> Data {
            calls.withLock { $0.append("events:\(page.afterSeq ?? 0)") }
            return Data(#"{"events":[],"hasMore":true,"lastSeq":9}"#.utf8)
        }
        func prompt(id: String, text: String) async throws -> Data {
            prompts.withLock { $0.append((id, text)) }
            return Data(#"{"prompt_id":"\#(id)","turn_id":"turn_9","queued":false}"#.utf8)
        }
        func cancel() async throws { calls.withLock { $0.append("cancel") } }
        func permission(id: String, option: String) async throws { calls.withLock { $0.append("permission:\(id):\(option)") } }
        func detach() async { calls.withLock { $0.append("detach") } }
        func close() async { calls.withLock { $0.append("close") } }
        func push(_ event: AgentSessionRemoteEvent) { handler.withLock { $0 }?(event) }
    }

    /// The wire's frames as text (Sendable), parsed on read.
    nonisolated final class Frames: Sendable {
        let texts = Mutex<[String]>([])
        let closes = Mutex<[String]>([])
        func append(_ text: String) { texts.withLock { $0.append(text) } }
        var items: [[String: Any]] {
            texts.withLock { $0 }.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        func reply(_ id: Int) -> [String: Any]? { items.first { $0["id"] as? Int == id } }
        func notifications(_ method: String) -> [[String: Any]] { items.filter { $0["method"] as? String == method } }
    }

    static func wire() async throws -> (RemoteAcpmuxWire, FakeClient, Frames) {
        let client = FakeClient()
        let frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub")
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, reason in frames.closes.withLock { $0.append(reason) } })
        return (wire, client, frames)
    }

    static func send(_ wire: RemoteAcpmuxWire, _ frame: String) {
        wire.send(frame) { _ in }
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func initializeSaysRemoteAndWatchListsOnlyThisSession() async throws {
        let (wire, client, frames) = try await Self.wire()
        Self.send(wire, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let origin = ((frames.reply(1)?["result"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        #expect(origin?["origin"] as? String == "remote")
        #expect((origin?["extensions"] as? [Any])?.isEmpty == true)
        Self.send(wire, #"{"jsonrpc":"2.0","id":2,"method":"_acpmux/watch","params":{"enabled":true}}"#)
        try await waitUntil { frames.reply(2) != nil }
        let sessions = (frames.reply(2)?["result"] as? [String: Any])?["sessions"] as? [[String: Any]]
        #expect(sessions?.map { $0["sessionId"] as? String } == ["acp_1"])
        #expect(client.calls.withLock { $0 } == ["attach:1"])
    }

    @Test func attachPagesAndPushesBecomeAcpmuxNotifications() async throws {
        let (wire, client, frames) = try await Self.wire()
        Self.send(wire, #"{"jsonrpc":"2.0","id":3,"method":"_acpmux/attach","params":{"sessionId":"sub","limit":400,"kinds":["transcript"],"eventStream":true}}"#)
        try await waitUntil { frames.reply(3) != nil }
        #expect((frames.reply(3)?["result"] as? [String: Any])?["lastSeq"] as? Int == 3)
        client.push(.record(Data(#"{"sessionId":"acp_1","seq":4,"kind":"agent_message"}"#.utf8)))
        client.push(.permission(Data(#"{"sessionId":"acp_1","permissionId":"perm_1"}"#.utf8)))
        try await waitUntil { frames.notifications("_acpmux/permission_pending").count == 1 }
        #expect((frames.notifications("_acpmux/event").first?["params"] as? [String: Any])?["seq"] as? Int == 4)
        // acpmux's id for the session is the chat's too, once an attach named it.
        Self.send(wire, #"{"jsonrpc":"2.0","id":4,"method":"_acpmux/events","params":{"sessionId":"acp_1","afterSeq":3}}"#)
        try await waitUntil { frames.reply(4) != nil }
        #expect(client.calls.withLock { $0 }.contains("events:3"))
        // The page's replay loop reads `more`.
        #expect((frames.reply(4)?["result"] as? [String: Any])?["more"] as? Bool == true)
        client.push(.changed(Data(#"{"sessionId":"acp_1","kind":"status","session":{"status":"idle"}}"#.utf8)))
        try await waitUntil { frames.notifications("_acpmux/session_changed").count == 1 }
    }

    @Test func promptsAreTextOnlyOnThisSession() async throws {
        let (wire, client, frames) = try await Self.wire()
        Self.send(wire, #"{"jsonrpc":"2.0","id":5,"method":"session/prompt","params":{"sessionId":"sub","prompt":[{"type":"text","text":"hello"}],"_meta":{"acpmux":{"promptId":"p-1"}}}}"#)
        try await waitUntil { frames.reply(5) != nil }
        #expect(client.prompts.withLock { $0.map(\.0) } == ["p-1"])
        #expect(client.prompts.withLock { $0.map(\.1) } == ["hello"])
        #expect((frames.notifications("_acpmux/prompt_accepted").first?["params"] as? [String: Any])?["turnId"] as? String == "turn_9")
        for (id, frame) in [
            (6, #"{"jsonrpc":"2.0","id":6,"method":"session/prompt","params":{"sessionId":"sub","prompt":[{"type":"image","data":"eA=="}]}}"#),
            (7, #"{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"other","prompt":[{"type":"text","text":"x"}]}}"#),
        ] {
            Self.send(wire, frame)
            try await waitUntil { frames.reply(id) != nil }
            #expect(((frames.reply(id)?["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String == RemoteAcpmuxWire.unsupported)
        }
        #expect(client.prompts.withLock { $0.count } == 1)
    }

    @Test func nothingThatStartsOrReconfiguresReachesTheOtherMachine() async throws {
        let (wire, client, frames) = try await Self.wire()
        let refused = ["session/new", "session/set_mode", "session/set_config_option", "_acpmux/kill", "_acpmux/harnesses",
                       "acp.trust.set", "file.search", "_acpmux/export", "_acpmux/peer_add", "session/fork"]
        for (offset, method) in refused.enumerated() {
            Self.send(wire, #"{"jsonrpc":"2.0","id":\#(100 + offset),"method":"\#(method)","params":{"sessionId":"sub","cwd":"/"}}"#)
        }
        try await waitUntil { (0..<refused.count).allSatisfy { frames.reply(100 + $0) != nil } }
        for offset in refused.indices {
            #expect(frames.reply(100 + offset)?["error"] != nil, "\(refused[offset]) is refused")
        }
        #expect(client.calls.withLock { $0 }.isEmpty)
        #expect(client.prompts.withLock { $0 }.isEmpty)
    }

    @Test func cancelAndPermissionAnswersGoToTheDaemon() async throws {
        let (wire, client, frames) = try await Self.wire()
        Self.send(wire, #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"sub"}}"#)
        Self.send(wire, #"{"jsonrpc":"2.0","id":8,"method":"_acpmux/permission_respond","params":{"sessionId":"sub","permissionId":"perm_1","optionId":"allow"}}"#)
        try await waitUntil { frames.reply(8) != nil }
        try await waitUntil { client.calls.withLock { $0 }.contains("cancel") }
        #expect(client.calls.withLock { $0 }.contains("permission:perm_1:allow"))
    }

    @Test func theAttachmentsEndClosesTheWireOnce() async throws {
        let (wire, client, frames) = try await Self.wire()
        Self.send(wire, #"{"jsonrpc":"2.0","id":9,"method":"_acpmux/attach","params":{"sessionId":"sub"}}"#)
        try await waitUntil { frames.reply(9) != nil }
        client.push(.closed("lagged"))
        client.push(.closed("overflow"))
        #expect(frames.closes.withLock { $0 } == ["lagged"])
        try await waitUntil { client.calls.withLock { $0 }.contains("close") }
        let sent = Mutex(true)
        wire.send(#"{"jsonrpc":"2.0","id":10,"method":"initialize"}"#) { value in sent.withLock { $0 = value } }
        #expect(!sent.withLock { $0 }, "a closed wire takes no frame")
    }
}
