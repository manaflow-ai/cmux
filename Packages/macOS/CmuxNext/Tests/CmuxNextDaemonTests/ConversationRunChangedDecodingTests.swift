import Foundation
import Testing
@testable import CmuxNextDaemon

struct ConversationRunChangedDecodingTests {
    @Test func liveRunKeepsThreadAndStartTimeInPersistedSummary() throws {
        let data = Data(#"""
        {
          "conversation": "conversation-1",
          "run": {
            "id": "run-1", "author": "agent_mux", "turn": "turn-1",
            "status": "done", "answers": ["message-1"],
            "thread_root": "thread-1", "started_at": 1793221200123, "rev": 17, "last_step_seq": 9
          },
          "steps": [{"id": "report:a1:1", "kind": "note", "text": "[a1] Verified"}]
        }
        """#.utf8)
        let event = try JSONDecoder().decode(ConversationRunChanged.self, from: data)
        #expect(event.run.threadRoot == "thread-1")
        #expect(event.run.startedAt == 1793221200123)
        #expect(event.summary.threadRoot == "thread-1")
        #expect(event.summary.startedAt == 1793221200123)
        #expect(event.summary.rev == 17)
        #expect(event.summary.lastStepSeq == 9)
        #expect(event.summary.turn == "turn-1")
        #expect(event.summary.answers == ["message-1"])
        #expect(event.steps?.first?.text == "[a1] Verified")
    }

    @Test func olderRunWithoutPlacementMetadataStillDecodes() throws {
        let data = Data(#"{"conversation":"conversation-1","run":{"id":"run-1","author":"agent_mux","status":"done"}}"#.utf8)
        let event = try JSONDecoder().decode(ConversationRunChanged.self, from: data)
        #expect(event.summary.threadRoot == nil)
        #expect(event.summary.startedAt == nil)
        #expect(event.steps == nil)
    }

    @Test func arbitraryToolInputsDoNotDropTheReportPage() throws {
        let inputs: [Any] = ["command", 42, ["id": 7, "message": false], [1, 2], NSNull()]
        var steps: [[String: Any]] = inputs.enumerated().map { index, input in
            ["id": "tool:\(index)", "kind": "tool", "tool": ["name": "unrelated", "input": input]]
        }
        steps.append(["id": "report:a1:1", "kind": "note", "text": "[a1] Verified", "at": 12345])
        let data = try JSONSerialization.data(withJSONObject: ["steps": steps, "has_more": false])
        let page = try JSONDecoder().decode(ConversationRunRows.self, from: data)
        #expect(page.steps.count == inputs.count + 1)
        #expect(page.steps.last?.text == "[a1] Verified")
        #expect(page.steps.last?.at == 12345)
    }

}
