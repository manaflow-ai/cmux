import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// A Cloud chat's side chats (`/side`, `/btw`): the handshake names the fork operation only where
/// the chat's machine opens side chats (`agent-session-side-v1`), the page's fork, side tag, side
/// question, prompt and take-back go to that machine's daemon for this chat and the side chats this
/// wire opened only, and an observer opens none.
@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxSideTests {
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let calls = Mutex<[String]>([])
        let isReadOnly: Bool
        let served: Bool

        init(readOnly: Bool = false, served: Bool = true) {
            isReadOnly = readOnly
            self.served = served
        }

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            Data(#"{"session":{"sessionId":"acp_1"},"events":[],"hasMore":false,"lastSeq":3}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":3}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data {
            calls.withLock { $0.append("chat-prompt \(text)") }
            return Data(#"{}"#.utf8)
        }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}

        func servesSide() async -> Bool { served }

        func side(_ op: String, _ fields: [String: any Sendable]) async throws -> Data {
            let shown = fields.keys.sorted().map { "\($0)=\(fields[$0].map { "\($0)" } ?? "")" }
            calls.withLock { $0.append(([op] + shown).joined(separator: " ")) }
            switch op {
            case "open": return Data(#"{"sessionId":"acp_side","_meta":{"acpmux":{"forkSeq":7}}}"#.utf8)
            case "btw": return Data(#"{"sessionId":"acp_btw"}"#.utf8)
            case "prompt": return Data(#"{"prompt_id":"p1","turn_id":"turn_2","queued":false}"#.utf8)
            default: return Data("{}".utf8)
            }
        }
    }

    typealias Frames = RemoteAcpmuxObserverTests.Frames

    static func wire(_ client: FakeClient) async throws -> (RemoteAcpmuxWire, Frames) {
        let frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub")
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        return (wire, frames)
    }

    static func error(_ frames: Frames, _ id: Int) -> String? {
        ((frames.reply(id)?["error"] as? [String: Any])?["data"] as? [String: Any])?["code"] as? String
    }

    static func result(_ frames: Frames, _ id: Int) -> [String: Any]? { frames.reply(id)?["result"] as? [String: Any] }

    @Test func theHandshakeNamesTheForkOnlyWhereTheMachineOpensSideChats() async throws {
        for (served, readOnly) in [(true, false), (false, false), (true, true)] {
            let (wire, frames) = try await Self.wire(FakeClient(readOnly: readOnly, served: served))
            wire.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#) { _ in }
            try await Self.waitUntil { frames.reply(1) != nil }
            let acpmux = (Self.result(frames, 1)?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            let operations = acpmux?["operations"] as? [String]
            #expect(operations == (served && !readOnly ? ["acp.session.fork", "_acpmux/btw"] : nil))
            #expect(acpmux?["origin"] as? String == "remote")
        }
    }

    @Test func aSideChatIsForkedTaggedPromptedAndTakenBackOnThisChatsDaemon() async throws {
        let client = FakeClient()
        let (wire, frames) = try await Self.wire(client)
        // Before any fork, no other session is this wire's: not to tag, prompt or end.
        for frame in [
            #"{"jsonrpc":"2.0","id":2,"method":"_acpmux/side","params":{"sessionId":"acp_side","chat":"sub"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"acp_side","prompt":[{"type":"text","text":"x"}]}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"_acpmux/kill","params":{"sessionId":"acp_side","purge":true}}"#,
            // A fork names this chat and one boundary, nothing else.
            #"{"jsonrpc":"2.0","id":5,"method":"acp.session.fork","params":{"sessionId":"acp_other","live":true}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"acp.session.fork","params":{"sessionId":"sub","live":true,"cwd":"/etc"}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"acp.session.fork","params":{"sessionId":"sub","throughSeq":0}}"#,
            #"{"jsonrpc":"2.0","id":8,"method":"acp.session.fork","params":{"sessionId":"sub","throughSeq":4,"live":true}}"#,
            #"{"jsonrpc":"2.0","id":9,"method":"_acpmux/btw","params":{"sessionId":"sub","question":"why?","model":"x"}}"#,
        ] {
            wire.send(frame) { _ in }
        }
        try await Self.waitUntil { (2...9).allSatisfy { frames.reply($0) != nil } }
        for id in 2...9 { #expect(Self.error(frames, id) == RemoteAcpmuxWire.unsupported, "frame \(id)") }
        #expect(client.calls.withLock { $0 }.isEmpty)

        wire.send(#"{"jsonrpc":"2.0","id":10,"method":"acp.session.fork","params":{"sessionId":"sub","throughSeq":7}}"#) { _ in }
        try await Self.waitUntil { frames.reply(10) != nil }
        #expect(Self.result(frames, 10)?["sessionId"] as? String == "acp_side")
        // The daemon's fork is this chat's fork for the host that opens it beside the chat.
        #expect(await RemoteAgentSessionLinks.shared.descends("acp_side", from: "sub"))

        wire.send(#"{"jsonrpc":"2.0","id":11,"method":"_acpmux/side","params":{"sessionId":"acp_side","chat":"sub"}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":12,"method":"_acpmux/side","params":{"sessionId":"acp_side","chat":"acp_other"}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":13,"method":"session/prompt","params":{"sessionId":"acp_side","prompt":[{"type":"text","text":"try it"}],"_meta":{"acpmux":{"promptId":"p1"}}}}"#) { _ in }
        // A side chat's prompt is text only.
        wire.send(#"{"jsonrpc":"2.0","id":14,"method":"session/prompt","params":{"sessionId":"acp_side","prompt":[{"type":"resource_link","uri":"file:///etc/passwd"}]}}"#) { _ in }
        try await Self.waitUntil { (11...14).allSatisfy { frames.reply($0) != nil } }
        #expect(Self.result(frames, 11) != nil)
        #expect(Self.error(frames, 12) == RemoteAcpmuxWire.unsupported)
        let accepted = (Self.result(frames, 13)?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        #expect(accepted?["promptId"] as? String == "p1")
        #expect(accepted?["turnId"] as? String == "turn_2")
        #expect(Self.error(frames, 14) == RemoteAcpmuxWire.unsupported)

        wire.send(#"{"jsonrpc":"2.0","id":15,"method":"acp.session.fork","params":{"sessionId":"sub","live":true}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":16,"method":"_acpmux/btw","params":{"sessionId":"sub","question":"why?"}}"#) { _ in }
        try await Self.waitUntil { frames.reply(15) != nil && frames.reply(16) != nil }
        #expect(Self.result(frames, 16)?["sessionId"] as? String == "acp_btw")

        wire.send(#"{"jsonrpc":"2.0","id":17,"method":"_acpmux/kill","params":{"sessionId":"acp_side","purge":true,"cancelFork":true}}"#) { _ in }
        try await Self.waitUntil { frames.reply(17) != nil }
        #expect(Self.result(frames, 17) != nil)
        // Taken back: no longer this wire's to prompt. The chat itself is never ended from here.
        wire.send(#"{"jsonrpc":"2.0","id":18,"method":"session/prompt","params":{"sessionId":"acp_side","prompt":[{"type":"text","text":"x"}]}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":19,"method":"_acpmux/kill","params":{"sessionId":"sub","purge":true}}"#) { _ in }
        try await Self.waitUntil { frames.reply(18) != nil && frames.reply(19) != nil }
        #expect(Self.error(frames, 18) == RemoteAcpmuxWire.unsupported)
        #expect(Self.error(frames, 19) == RemoteAcpmuxWire.unsupported)

        #expect(client.calls.withLock { $0 }.sorted() == [
            "btw text=why?",
            "discard session=acp_side",
            "open live=true",
            "open through_seq=7",
            "prompt prompt_id=p1 session=acp_side text=try it",
        ])
    }

    @Test func anObserverOpensNoSideChat() async throws {
        let client = FakeClient(readOnly: true)
        let (wire, frames) = try await Self.wire(client)
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"acp.session.fork","params":{"sessionId":"sub","live":true}}"#) { _ in }
        wire.send(#"{"jsonrpc":"2.0","id":3,"method":"_acpmux/btw","params":{"sessionId":"sub","question":"why?"}}"#) { _ in }
        try await Self.waitUntil { frames.reply(2) != nil && frames.reply(3) != nil }
        #expect(Self.error(frames, 2) == RemoteAcpmuxWire.readOnly)
        #expect(Self.error(frames, 3) == RemoteAcpmuxWire.readOnly)
        #expect(client.calls.withLock { $0 }.isEmpty)
    }

    @Test func aForkBoundaryIsOneCompletedTurnOrTheChatAsItIsNow() {
        #expect(RemoteAcpmuxWire.sideBoundary(["sessionId": "sub", "throughSeq": 7])?["through_seq"] as? UInt64 == 7)
        #expect(RemoteAcpmuxWire.sideBoundary(["sessionId": "sub", "live": true])?["live"] as? Bool == true)
        #expect(RemoteAcpmuxWire.sideBoundary(["sessionId": "sub"]) == nil)
        #expect(RemoteAcpmuxWire.sideBoundary(["sessionId": "sub", "live": false]) == nil)
        #expect(RemoteAcpmuxWire.sideBoundary(["sessionId": "sub", "throughSeq": 7, "name": "x"]) == nil)
        #expect(RemoteAcpmuxWire.sideBoundary(["sessionId": "sub", "live": true, "cancelToken": "t"]) == nil)
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
