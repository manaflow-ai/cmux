@testable import CmuxMobileAgentChat
import Foundation
import Testing
@testable import CmuxMobileLive

@MainActor
@Suite struct RetriedTurnLiveTests {
    final class Source: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "Chat", harness: "codex", agentName: "Codex",
                                          cwd: "~", workspaceTitle: "Project", macName: "Mac")
        var eventsToReplay: [AgentSessionEvent] = []
        func events() -> AsyncStream<AgentSessionEvent> {
            AsyncStream { continuation in
                continuation.finish()
            }
        }
        func send(_ intent: AgentClientIntent) {}
    }

    @Test func aRetryReplacesTheFailedTurnDuringHistoryReplay() throws {
        let records = AcpmuxRecords(sessionID: "s")
        let lines = [
            #"{"dir":"mux","kind":"user_message","msg":{"turnId":"t1","promptId":"p1","text":"Read this","images":[{"id":"image"}]}}"#,
            #"{"dir":"mux","kind":"turn_result","msg":{"turnId":"t1","status":"failed","errorText":"unavailable"}}"#,
            #"{"dir":"mux","kind":"user_message","msg":{"turnId":"t2","promptId":"p1~resume-1","text":"Continue","_meta":{"provenance":{"kind":"auto_resume","turnId":"t1","manual":true}}}}"#,
            #"{"dir":"mux","kind":"turn_result","msg":{"turnId":"t2","status":"completed"}}"#,
        ]
        let source = Source()
        source.eventsToReplay = try lines.flatMap { line in
            records.map(try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))
        }
        let store = AgentChatStore(source: source)
        store.apply(.batch(source.eventsToReplay))
        #expect(store.turns.count == 1)
        let turn = try #require(store.turns.last)
        #expect(turn.id == "t2")
        #expect(turn.prompt == "Read this")
        #expect(turn.attachments.map(\.recordedImageID) == ["image"])
        #expect(turn.status == .completed)
        #expect(turn.errorText == nil)
    }
}
