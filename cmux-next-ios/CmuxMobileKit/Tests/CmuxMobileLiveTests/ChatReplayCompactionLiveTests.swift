import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// An open chat keeps what it streamed for a later reader. A long reply arrives one
/// chunk per few tokens; the source keeps it as one joined chunk per message, so its
/// buffer grows with messages rather than tokens, and a later reader still draws
/// exactly the transcript the first one drew.
@MainActor
@Suite(.timeLimit(.minutes(2))) struct ChatReplayCompactionLiveTests {
    nonisolated static let chunks = 3000

    nonisolated static func fakeAcpmux() -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            func event(_ seq: Int, _ body: String) -> Data {
                Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s1","seq":\#(seq),"at":5,\#(body)}}"#.utf8)
            }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"codex","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                var out = [reply(#"{"session":{"sessionId":"s1","status":"running","pending":[]},"hasMore":false,"events":[]}"#)]
                out.append(event(1, #""dir":"mux","kind":"user_message","msg":{"text":"go","promptId":"p1","turnId":"t1"}"#))
                out.append(event(2, #""dir":"mux","kind":"turn_started","msg":{"turnId":"t1"}"#))
                for index in 0..<chunks {
                    let kind = index == chunks / 2 ? "agent_thought_chunk" : "agent_message_chunk"
                    out.append(event(3 + index, #""dir":"in","kind":"\#(kind)","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"\#(kind)","content":{"type":"text","text":"w\#(index) "}}}}"#))
                }
                out.append(event(3 + chunks, #""dir":"mux","kind":"turn_result","msg":{"status":"completed","turnId":"t1"}"#))
                return out
            default:
                return [reply("{}")]
            }
        }
    }

    @Test func streamedChunksAreKeptJoinedAndReplayTheSameTranscript() async throws {
        let hub = AcpmuxHub()
        await hub.bind(try await Self.fakeAcpmux().openChannel(service: "acpmux", args: [:]))
        let summary = AgentSessionSummary(id: "s1", name: "Fix", harness: "codex", agentName: "Codex", cwd: "/tmp/w",
                                          workspaceTitle: "w", macName: "mini")
        let source = hub.source(sessionID: "s1", summary: summary)
        let first = AgentChatStore(source: source)
        await ChatOpenSnapshotLiveTests.waitUntil { first.turns.last?.status == .completed }

        // user message, turn start, message, thought, message, turn result, plus state events:
        // a handful, never one per chunk.
        #expect(source.replayCount < 40, "replay holds \(source.replayCount) events for \(Self.chunks) chunks")

        let second = AgentChatStore(source: source)
        await ChatOpenSnapshotLiveTests.waitUntil { second.turns.last?.status == .completed }
        #expect(Self.text(second) == Self.text(first))
        #expect(Self.text(first).count == 3)
        #expect(Self.text(first).joined().contains("w\(Self.chunks - 1) "))
    }

    /// What a store draws, without the ids it makes up for unnamed messages.
    static func text(_ store: AgentChatStore) -> [String] {
        store.turns.flatMap(\.items).compactMap { item in
            switch item {
            case .message(_, let markdown): "message:" + markdown
            case .thought(_, let text): "thought:" + text
            default: nil
            }
        }
    }
}
