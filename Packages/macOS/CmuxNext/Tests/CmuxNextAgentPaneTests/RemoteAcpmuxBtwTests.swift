import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// `/btw <question>` on a Cloud chat (cmuxterm-hq#7856: "whatever works on a local chat should
/// work on a Cloud chat"): the composer's inline `_acpmux/btw` goes to the owning daemon for this
/// chat only (`agent-session-btw-v1`), the answer's text comes back, acpmux's refusal comes back
/// with its reason, the handshake names the `btw_inline` feature, and an observer never asks one.
@Suite(.timeLimit(.minutes(1))) struct RemoteAcpmuxBtwTests {
    nonisolated final class FakeClient: AgentSessionRemoteClient {
        let questions = Mutex<[String]>([])
        let isReadOnly: Bool

        init(readOnly: Bool = false) { isReadOnly = readOnly }

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            Data(#"{"session":{"sessionId":"acp_1"},"events":[],"hasMore":false,"lastSeq":3}"#.utf8)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { Data(#"{"events":[],"hasMore":false,"lastSeq":3}"#.utf8) }
        func prompt(id: String, text: String) async throws -> Data { Data(#"{}"#.utf8) }
        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {}
        func detach() async {}
        func close() async {}
        func setModel(_ modelId: String) async throws -> Data { Data("{}".utf8) }
        func setMode(_ modeId: String) async throws -> Data { Data("{}".utf8) }
        func setConfig(id configId: String, value: String) async throws -> Data { Data("{}".utf8) }
        func login(_ op: String, _ fields: [String: String]) async throws -> Data { Data("{}".utf8) }

        func btw(_ question: String) async throws -> Data {
            questions.withLock { $0.append(question) }
            if question == "no read-only mode" { return Data(#"{"refused":{"reason":"btw.no_read_only_mode"}}"#.utf8) }
            return Data(#"{"text":"It flaked on a timeout."}"#.utf8)
        }
    }

    typealias Frames = RemoteAcpmuxObserverTests.Frames

    static func wire(_ client: FakeClient) async throws -> (RemoteAcpmuxWire, Frames) {
        let frames = Frames()
        let wire = RemoteAcpmuxWire(client: client, session: "sub")
        try await wire.open(onFrame: { frames.append($0) }, onClose: { _, _ in })
        return (wire, frames)
    }

    static func error(_ frames: Frames, _ id: Int) -> [String: Any]? {
        (frames.reply(id)?["error"] as? [String: Any])?["data"] as? [String: Any]
    }

    @Test func theHandshakeNamesTheInlineFeature() async throws {
        let (wire, frames) = try await Self.wire(FakeClient())
        wire.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#) { _ in }
        try await Self.waitUntil { frames.reply(1) != nil }
        let acpmux = ((frames.reply(1)?["result"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        #expect((acpmux?["features"] as? [String])?.contains("btw_inline") == true)
    }

    @Test func anInlineQuestionGoesToThisChatsDaemon() async throws {
        let client = FakeClient()
        let (wire, frames) = try await Self.wire(client)
        for frame in [
            #"{"jsonrpc":"2.0","id":2,"method":"_acpmux/btw","params":{"sessionId":"sub","question":"why?","inline":true}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"_acpmux/btw","params":{"sessionId":"sub","question":"no read-only mode","inline":true}}"#,
            // Another chat, a side session to open (no `inline`), a model, or no question goes nowhere.
            #"{"jsonrpc":"2.0","id":4,"method":"_acpmux/btw","params":{"sessionId":"acp_other","question":"why?","inline":true}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"_acpmux/btw","params":{"sessionId":"sub","question":"why?"}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"_acpmux/btw","params":{"sessionId":"sub","question":"why?","inline":true,"model":"opus"}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/btw","params":{"sessionId":"sub","question":"  ","inline":true}}"#,
        ] {
            wire.send(frame) { _ in }
        }
        try await Self.waitUntil { (2...7).allSatisfy { frames.reply($0) != nil } }
        #expect((frames.reply(2)?["result"] as? [String: Any])?["text"] as? String == "It flaked on a timeout.")
        #expect(Self.error(frames, 3)?["reason"] as? String == "btw.no_read_only_mode")
        #expect(Self.error(frames, 3)?["code"] as? String == RemoteAcpmuxWire.btwRefused)
        for id in 4...7 { #expect(Self.error(frames, id)?["code"] as? String == RemoteAcpmuxWire.unsupported) }
        #expect(client.questions.withLock { $0 } == ["why?", "no read-only mode"])
    }

    @Test func anObserverNeverAsks() async throws {
        let client = FakeClient(readOnly: true)
        let (wire, frames) = try await Self.wire(client)
        wire.send(#"{"jsonrpc":"2.0","id":2,"method":"_acpmux/btw","params":{"sessionId":"sub","question":"why?","inline":true}}"#) { _ in }
        try await Self.waitUntil { frames.reply(2) != nil }
        #expect(Self.error(frames, 2)?["code"] as? String == RemoteAcpmuxWire.readOnly)
        #expect(client.questions.withLock { $0 }.isEmpty)
    }

    private static func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
