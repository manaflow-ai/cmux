import Foundation
import Testing
@testable import CmuxAgentJournal

@Suite("Agent goal lifecycle")
struct AgentGoalLifecycleTests {
    @Test("goal state carries its generation and provenance on the wire")
    func wireRoundTrip() throws {
        let goal = AgentGoalLifecycle(
            state: .complete,
            generation: "codex-goal-42",
            updatedAtMs: 1_756_000_000_123,
            provenance: "provider_hook"
        )

        let data = try JSONEncoder().encode(goal)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["state"] as? String == "complete")
        #expect(object["generation"] as? String == "codex-goal-42")
        #expect(object["updated_at_ms"] as? Int64 == 1_756_000_000_123)
        #expect(object["provenance"] as? String == "provider_hook")
        #expect(try JSONDecoder().decode(AgentGoalLifecycle.self, from: data) == goal)
    }

    @Test("only complete is terminal")
    func terminalState() {
        #expect(AgentGoalLifecycleState.complete.isTerminal)
        #expect(!AgentGoalLifecycleState.active.isTerminal)
        #expect(!AgentGoalLifecycleState.paused.isTerminal)
        #expect(!AgentGoalLifecycleState.blocked.isTerminal)
        #expect(!AgentGoalLifecycleState.unmanaged.isTerminal)
        #expect(!AgentGoalLifecycleState.unknown.isTerminal)
    }
}
