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

    /// Slice 3 (user 2026-11-03, msg 19968): the prompt's `_meta.cmux.sender` says who wrote a tell, the person
    /// or the Chief, in the direct input and in a Codex envelope.
    @Test func aTellKeepsItsSenderMeta() throws {
        let run = try mapped([
            ["id": "tool:1", "kind": "tool", "status": "done", "at": 1000,
             "tool": ["name": "tell", "input": ["id": "a1", "message": "from the person",
                                                "_meta": ["cmux": ["sender": "human:p_lawrence"]]]]],
            ["id": "tool:2", "kind": "tool", "status": "done", "at": 2000,
             "tool": ["name": "mcp_tool_call", "input": ["server": "optchat", "tool": "tell",
                                                          "arguments": ["id": "a1", "message": "from the Chief",
                                                                        "_meta": ["cmux": ["sender": "chief:agent_mux"]]]]]],
            ["id": "tool:3", "kind": "tool", "status": "done", "at": 3000,
             "tool": ["name": "tell", "input": ["id": "a1", "message": "no meta", "_meta": ["cmux": ["sender": 7]]]]],
        ])
        #expect(run.messages.map(\.text) == ["from the person", "from the Chief", "no meta"])
        #expect(run.messages.map(\.sender) == ["human:p_lawrence", "chief:agent_mux", nil])
    }

    /// A spawn is the Chief's first message to each agent it started (user 2026-11-04, msg 21664: a pill named
    /// "User (Nov 4)" from a later tell). Each task goes to the id the answer's `Started` line gives it, in order,
    /// so the pill and the agent's chat take the task's `Title:` line. Each task's `- a<N>:` answer line names its
    /// agent, a queued or failed one too.
    @Test(arguments: ["mcp__optchat__spawn", "spawn", "optchat.spawn"])
    func aSpawnIsTheTaskOfEachAgentItStarted(_ name: String) throws {
        let tasks = ["Title: Bubble tail last only\n\nOnly the last bubble gets the tail.", "Title: Subagent link opens pane\n\nOpen it on the right."]
        let output = "Started a988 in /Users/me/fun/cmux.\n- a988: runs hidden.\n- a989: did not start (no PTYs)\nTell the user only what these lines say."
        let run = try mapped([["id": "tool:7", "kind": "tool", "status": "done", "at": 4000,
                              "tool": ["name": name, "input": ["tasks": tasks, "cwd": "~/fun/cmux"], "output": output]]])
        #expect(run.messages.map(\.peer) == ["a988", "a989"])
        #expect(run.messages.map(\.text) == tasks)
        #expect(run.messages.map(\.outgoing) == [true, true])
        #expect(Set(run.messages.map(\.id)).count == 2)
    }

    /// A Codex envelope (`mcp_tool_call` to optchat's spawn) maps the same; a spawn still running (no answer yet) or
    /// whose answer names a different count of agents maps nothing rather than a wrong name.
    @Test func aSpawnEnvelopeMapsAndAnUnmatchedAnswerMapsNothing() throws {
        let tasks = ["Title: One\n\nGo.", "Title: Two\n\nGo."]
        let envelope = try mapped([["id": "tool:1", "kind": "tool", "status": "done",
                                   "tool": ["name": "mcp_tool_call", "input": ["server": "optchat", "tool": "spawn", "arguments": ["tasks": tasks]],
                                            "output": "Routed: claude.\nStarted a1, a2 on the cloud VM vm-1 (acpmux peer), in /work.\n- a1: on vm-1.\n- a2: queued (cap)"]]])
        #expect(envelope.messages.map(\.peer) == ["a1", "a2"])
        let running = try mapped([["id": "tool:2", "kind": "tool", "status": "running", "tool": ["name": "spawn", "input": ["tasks": tasks]]]])
        #expect(running.messages.isEmpty)
        let short = try mapped([["id": "tool:3", "kind": "tool", "status": "done",
                                "tool": ["name": "spawn", "input": ["tasks": tasks], "output": "Started a1 in /work.\n- a1: runs hidden."]]])
        #expect(short.messages.isEmpty)
    }
}
