import Testing
@testable import CmuxNextAgentPane

/// `sessions.promptSuggestions`: the App's setting turns suggested tasks on
/// for the pages and for the next acpmux daemon (``AcpmuxHost`` reads
/// ``AgentPaneSuggestedTasks/forNextDaemon`` off the main actor).
@Suite(.serialized)
@MainActor
struct AgentPaneSuggestedTasksSettingTests {
    @Test func theSettingReachesTheNextDaemonAtOnceAndBack() async {
        let debugOn = AgentPaneTunables.suggestedTasks.value
        let tasks = AgentPaneSuggestedTasks()
        tasks.setting = { true }
        #expect(tasks.isOn)
        // Set at once, before the observation runs: a daemon prewarmed at launch sees it.
        #expect(AgentPaneSuggestedTasks.forNextDaemon.isOn)

        tasks.setting = { false }
        #expect(tasks.isOn == debugOn)
        #expect(AgentPaneSuggestedTasks.forNextDaemon.isOn == debugOn)
        // The observation's later passes keep it there.
        for _ in 0..<50 { await Task.yield() }
        #expect(AgentPaneSuggestedTasks.forNextDaemon.isOn == debugOn)
    }

    @Test func aReleasedInstanceLeavesTheSharedFlagAlone() async {
        var released: AgentPaneSuggestedTasks? = AgentPaneSuggestedTasks()
        released?.setting = { true }
        released = nil
        let live = AgentPaneSuggestedTasks()
        live.setting = { true }
        for _ in 0..<50 { await Task.yield() }
        #expect(released == nil)
        #expect(AgentPaneSuggestedTasks.forNextDaemon.isOn)
        live.setting = { false }
    }
}
