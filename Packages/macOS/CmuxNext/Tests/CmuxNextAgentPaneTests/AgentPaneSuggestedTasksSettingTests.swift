import Testing
@testable import CmuxNextAgentPane

/// `sessions.promptSuggestions`: the App's setting turns suggested tasks on
/// for the pages and for the next acpmux daemon (``AcpmuxHost`` reads
/// ``AgentPaneSuggestedTasks/forNextDaemon`` off the main actor).
@Suite(.serialized)
@MainActor
struct AgentPaneSuggestedTasksSettingTests {
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }

    @Test func theSettingReachesThePagesAndTheNextDaemon() async {
        let tasks = AgentPaneSuggestedTasks()
        tasks.setting = { true }
        #expect(tasks.isOn)
        await settle { AgentPaneSuggestedTasks.forNextDaemon.isOn }
        #expect(AgentPaneSuggestedTasks.forNextDaemon.isOn)

        tasks.setting = { false }
        await settle { !AgentPaneSuggestedTasks.forNextDaemon.isOn }
        #expect(tasks.isOn == AgentPaneTunables.suggestedTasks.value)
    }
}
