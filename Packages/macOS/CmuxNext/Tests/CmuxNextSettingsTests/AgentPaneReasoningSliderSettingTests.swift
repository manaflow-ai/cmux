import CmuxNextSettings
import Testing

/// The reasoning slider is a Debug Settings opt-in (`agent.reasoningSlider`), not a cmux.json key:
/// the host sets ``AgentPaneComposerSetting/reasoningSlider`` from the toggle and the page reads it
/// from the `composer` event (webviews composerSettings.ts).
struct AgentPaneReasoningSliderSettingTests {
    @Test func offByDefaultAndOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.reasoningSlider == false)
        #expect(snapshot.agentPaneComposer.reasoningSliderStyle == "accent")
        #expect(snapshot.agentPaneComposer.spellChecking == false)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["reasoningSlider"])?.boolValue == false)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["reasoningSliderStyle"])?.stringValue == "accent")
    }

    @Test func cmuxJSONCannotTurnItOn() {
        let root = JSONValue.object(["agentPane": .object(["reasoningSlider": .bool(true)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.reasoningSlider == false)
        #expect(SettingsSchema.descriptor(for: ["agentPane", "reasoningSlider"]) == nil)
    }

    @Test func theToggleReachesThePage() {
        var setting = AgentPaneComposerSetting.fallback
        setting.reasoningSlider = true
        setting.reasoningSliderStyle = "minimal"
        #expect(setting.pageValue.value(at: ["reasoningSlider"])?.boolValue == true)
        #expect(setting.pageValue.value(at: ["reasoningSliderStyle"])?.stringValue == "minimal")
        #expect(setting.pageValue.value(at: ["showDictation"])?.boolValue == true)
        #expect(setting.pageValue.value(at: ["spellChecking"])?.boolValue == false)
    }

    @Test func spellCheckingIsAnOptInSetting() {
        let root = JSONValue.object(["agentPane": .object(["spellChecking": .bool(true)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.spellChecking == true)
        #expect(SettingsSchema.descriptor(for: ["agentPane", "spellChecking"]) != nil)
    }

}
