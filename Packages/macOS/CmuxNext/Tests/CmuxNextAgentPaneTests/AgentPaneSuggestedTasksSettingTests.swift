import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// `sessions.promptSuggestions`: the App's setting decides whether agents suggest tasks,
/// for the pages and for the next acpmux daemon (``AcpmuxHost`` reads
/// ``AgentPaneSuggestedTasks/forNextDaemon`` off the main actor). The Debug toggle
/// `agent.suggestedTasks` is off by default and only forces them on.
/// The checks run with no suspension in between: other suites' instances
/// (``AgentPaneSuggestedTasks/shared``) write the same flag from their
/// observations, which can only interleave at an await.
@Suite(.serialized)
@MainActor
struct AgentPaneSuggestedTasksSettingTests {
    @Test func onByDefaultAndTheDebugToggleDoesNotForceThem() {
        #expect(SessionSettings.promptSuggestionsDefault)
        #expect(!AgentPaneTunables.suggestedTasks.defaultValue)
        #expect(AgentPaneSuggestedTasks().isOn)
    }

    /// Before the fix the Debug toggle, on by default, was ORed in, so turning the setting off did nothing.
    @Test func turningTheSettingOffTurnsThemOffAtOnceAndBack() {
        let tasks = AgentPaneSuggestedTasks()
        tasks.setting = { false }
        #expect(!tasks.isOn)
        // Set at once, before the observation runs: a daemon prewarmed at launch sees it.
        #expect(!AgentPaneSuggestedTasks.forNextDaemon.isOn)

        tasks.setting = { true }
        #expect(tasks.isOn)
        #expect(AgentPaneSuggestedTasks.forNextDaemon.isOn)
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
