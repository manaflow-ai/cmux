import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextTestSupport
import Testing

@MainActor @Suite(.serialized, .closesItsWindows)
struct AgentPageHibernationWorkspaceRetryTests {
    @Test func workspaceReleaseRetriesWhenTheChatDefaultIsDisabled() async throws {
        let rig = AgentPageHibernationTests.Rig()
        defer { rig.window.closeAfterTest() }
        rig.hibernation.update(chatSetting: ChatPageHibernationSettings(enabled: false))
        var reads = 0
        rig.hibernation.wakeState = { _ in
            reads += 1
            return AgentPaneWakeState(holdsPrompts: reads == 1)
        }
        _ = try rig.hiddenChat("tab_workspace", session: "s-workspace")
        rig.advance(minutes: 1)
        #expect(!rig.hibernation.hasDeadline)
        #expect(rig.hibernation.releaseForWorkspace("tab_workspace") == nil)
        await rig.settle { rig.hibernation.hasDeadline }
        #expect(reads == 1)
        #expect(rig.hibernation.hasDeadline, "a workspace release must retry even with automatic chat release off")
        rig.elapsed += .seconds(AgentPageHibernation.keptRecheck + 1)
        rig.hibernation.replan()
        await rig.settle { rig.tabs.existingView("tab_workspace") == nil }
        #expect(reads == 2)
        #expect(rig.tabs.existingView("tab_workspace") == nil)
    }
}
