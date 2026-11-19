import CmuxNextSettings
import Testing
@testable import CmuxNextAgentPane

/// Settings > Advanced > Experiments reaches the agent page as one `experiments` object, and the
/// header state carries the chat's workspace for the glass toolbar's title.
@Suite
@MainActor
struct AgentPaneExperimentsTests {
    @Test func theSwitchesGoToThePageAsOneObject() {
        let switches = ["glassToolbarGroups": true, "other": false]
        let event = AgentPaneExperiments.event(switches)
        #expect(event.kind == "experiments")
        #expect(event.value == ["glassToolbarGroups": .bool(true), "other": .bool(false)])
        #expect(AgentPaneExperiments.script(["glassToolbarGroups": true])
            == #"window.cmuxAcpmuxBridge?.applyExperiments?.({"glassToolbarGroups":true});"#)
    }

    @Test func settingTheSameSwitchesIsNoChange() {
        let experiments = AgentPaneExperiments()
        #expect(experiments.set(["glassToolbarGroups": false]))
        #expect(!experiments.set(["glassToolbarGroups": false]))
        #expect(experiments.set(["glassToolbarGroups": true]))
    }

    @Test func theHeaderStateCarriesTheWorkspace() {
        var state = AgentPaneHeaderState(sessionInfo: false, headerControls: .standard, headerMotion: .still)
        #expect(state.json.objectValue?["workspace"] == .null)
        let before = state
        state.workspace = AgentPaneHeaderWorkspace(title: "cmux", chats: 3)
        #expect(state.json.objectValue?["workspace"] == ["title": .string("cmux"), "chats": JSONValue(3)])
        // A rename or another chat in the workspace is a change the watch pushes.
        #expect(!state.shows(before))
        var renamed = state
        renamed.workspace?.title = "docs"
        #expect(!renamed.shows(state))
    }
}
