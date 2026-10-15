import CmuxNextSettings
import Testing

/// `agentPane.reasoningSlider`: the composer's reasoning menu draws the stepped slider instead of
/// its list of levels. The list stays the default; the page reads the flag from the `composer`
/// event (webviews composerSettings.ts), and Settings offers the row under Agent Chat.
struct AgentPaneReasoningSliderSettingTests {
    @Test func offByDefault() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.reasoningSlider == false)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["reasoningSlider"])?.boolValue == false)
    }

    @Test func onReachesThePage() {
        let root = JSONValue.object(["agentPane": .object(["reasoningSlider": .bool(true)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.reasoningSlider == true)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["reasoningSlider"])?.boolValue == true)
        // The other composer flags keep their defaults.
        #expect(snapshot.agentPaneComposer.showDictation == true)
    }

    @Test func aBadValueIsTheDefaultPlusADiagnostic() {
        let root = JSONValue.object(["agentPane": .object(["reasoningSlider": .string("yes")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.reasoningSlider == false)
        #expect(snapshot.diagnostics.contains { $0.path == "agentPane.reasoningSlider" })
    }

    @Test func settingsOffersTheToggle() {
        let descriptor = SettingsSchema.descriptor(for: AgentPaneComposerSetting.reasoningSliderPath)
        #expect(descriptor?.kind == .toggle)
        #expect(descriptor?.defaultValue == .bool(false))
    }
}
