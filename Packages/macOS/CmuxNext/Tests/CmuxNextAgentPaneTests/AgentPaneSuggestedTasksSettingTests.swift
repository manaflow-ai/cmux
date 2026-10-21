import Testing
@testable import CmuxNextAgentPane

/// `sessions.promptSuggestions`: the App's setting turns suggested tasks on
/// for the pages and for the next acpmux daemon (``AcpmuxHost`` reads
/// ``AgentPaneSuggestedTasks/forNextDaemon`` off the main actor).
/// The checks run with no suspension in between: other suites' instances
/// (``AgentPaneSuggestedTasks/shared``) write the same flag from their
/// observations, which can only interleave at an await.
@Suite(.serialized)
@MainActor
struct AgentPaneSuggestedTasksSettingTests {
    @Test func theSettingReachesTheNextDaemonAtOnceAndBack() {
        let debugOn = AgentPaneTunables.suggestedTasks.value
        let tasks = AgentPaneSuggestedTasks()
        tasks.setting = { true }
        #expect(tasks.isOn)
        // Set at once, before the observation runs: a daemon prewarmed at launch sees it.
        #expect(AgentPaneSuggestedTasks.forNextDaemon.isOn)

        tasks.setting = { false }
        #expect(tasks.isOn == debugOn)
        #expect(AgentPaneSuggestedTasks.forNextDaemon.isOn == debugOn)
    }

    @Test func aReleasedInstanceIsFreed() {
        weak var released: AgentPaneSuggestedTasks?
        do {
            let tasks = AgentPaneSuggestedTasks()
            tasks.setting = { true }
            released = tasks
        }
        // Its observation holds it weakly and its deinit cancels the task.
        #expect(released == nil)
    }
}
