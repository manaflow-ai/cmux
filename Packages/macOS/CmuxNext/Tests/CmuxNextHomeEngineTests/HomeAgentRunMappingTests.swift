import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextHomeEngine

struct HomeAgentRunMappingTests {
    func mapped(_ steps: [[String: Any]]) throws -> HomeAgentRun {
        let data = try JSONSerialization.data(withJSONObject: [
            "conversation": "conversation-1",
            "run": ["id": "run-1", "author": "agent_mux", "status": "done", "started_at": 1000],
            "steps": steps
        ])
        let event = try JSONDecoder().decode(ConversationRunChanged.self, from: data)
        return HomeAgentRunMapping.run(event.summary, conversation: event.conversation, steps: event.steps ?? [],
                                       author: { ParticipantID($0) })
    }

    @Test(arguments: [
        "outcome: refused. a1 was cancelled; control(action: \"restart\", id: \"a1\") brings it back",
        "outcome: refused. a1 finished and its cloud VM vm-1 was deleted after its work was pushed; spawn a new subagent for more work"
    ])
    func completedTellWithRefusedOutcomeShowsReason(_ output: String) throws {
        let body = String(repeating: "Full message 🦀\n", count: 100)
        let run = try mapped([["id": "tool:1", "kind": "tool", "status": "done", "at": 9000,
                              "tool": ["name": "mcp__optchat__tell", "input": ["id": "a1", "message": body],
                                       "output": output, "started_at": 2000]]])
        let message = try #require(run.messages.first)
        let failureLabel = try #require(StatusIndicatorState.error.shortLabel)
        #expect(message.text == body + "\n[\(failureLabel): \(output)]")
        #expect(message.peer == "a1")
        #expect(message.outgoing)
        #expect(message.date == Date(timeIntervalSince1970: 9))
    }

    @Test func codexTellEnvelopeMapsOnlyOptchatAndRetainsFullBody() throws {
        let body = String(repeating: "Please verify. ", count: 100)
        func step(_ server: String) -> [String: Any] {
            ["id": "tool:\(server)", "kind": "tool", "status": "done", "at": 5000,
             "tool": ["name": "mcp_tool_call", "input": ["server": server, "tool": "tell",
                                                            "arguments": ["id": "a1", "message": body]],
                      "output": "outcome: done. delivered"]]
        }
        let run = try mapped([step("optchat"), step("other-server")])
        #expect(run.messages.count == 1)
        #expect(run.messages.first?.text == body)
        #expect(run.messages.first?.peer == "a1")
    }

    @Test func reportUsesItsOwnTimeAndSurvivesUnrelatedToolInputs() throws {
        let inputs: [Any] = ["command", 42, ["id": 7, "message": [1, 2]], ["input": "value"], [1, 2]]
        var steps: [[String: Any]] = inputs.enumerated().map { index, input in
            ["id": "tool:\(index)", "kind": "tool", "tool": ["name": "other", "input": input]]
        }
        steps.append(["id": "report:a1:1", "kind": "note", "text": "[a1] Verified 🦀", "at": 7000])
        let run = try mapped(steps)
        #expect(run.messages.count == 1)
        #expect(run.messages.first?.text == "Verified 🦀")
        #expect(run.messages.first?.outgoing == false)
        #expect(run.messages.first?.date == Date(timeIntervalSince1970: 7))
    }

    @Test func cloudSequenceOrdersMessagesWithoutBecomingAnUpdateRevision() throws {
        let run = try mapped([["id": "tool:1", "seq": 12, "kind": "tool", "status": "running",
                              "tool": ["name": "tell", "input": ["id": "a1", "message": "check"]]]])
        #expect(run.revision == 0)
        #expect(run.messages.first?.sequence == 12)
        #expect(run.messages.first?.revision == 0)
    }

    @Test func failedTellWithoutOutputIsStillMarkedFailed() throws {
        let run = try mapped([["id": "tool:1", "kind": "tool", "status": "failed",
                              "tool": ["name": "tell", "input": ["id": "a1", "message": "check"]]]])
        let failureLabel = try #require(StatusIndicatorState.error.shortLabel)
        #expect(run.messages.first?.text == "check\n[\(failureLabel)]")
    }
}
