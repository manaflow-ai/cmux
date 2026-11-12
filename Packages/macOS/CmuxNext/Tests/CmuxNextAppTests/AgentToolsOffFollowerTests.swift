import CmuxNextAgentIntegrations
import Testing

/// An answer that turns to `off` on any surface takes cmux's entry out of the person's agents.
@MainActor @Suite struct AgentToolsOffFollowerTests {
    @MainActor final class Recorder: AgentToolsSource {
        var removes = 0
        func agentToolsChoice() -> AgentToolsChoice { .ask }
        func setAgentToolsChoice(_ choice: AgentToolsChoice) async -> Bool { true }
        func agentToolsAgents() async -> [AgentToolsAgent] { [] }
        func applyAgentTools(remove: Bool) async -> [AgentToolsAgent]? {
            if remove { removes += 1 }
            return []
        }
    }

    @Test func aChangeToOffRemovesOnceAndTheLaunchAnswerIsNotAChange() async {
        let source = Recorder()
        let follower = AgentToolsOffFollower(source: source)
        await follower.observe(.off)
        #expect(source.removes == 0, "off at launch is where it starts, not a change")
        for next in [AgentToolsChoice.off, .on, .on, .off, .off, .ask, .off] {
            await follower.observe(next)
        }
        #expect(source.removes == 2, "on to off, and ask to off; staying off removes nothing more")
        #expect(follower.removals == 2)
    }
}
