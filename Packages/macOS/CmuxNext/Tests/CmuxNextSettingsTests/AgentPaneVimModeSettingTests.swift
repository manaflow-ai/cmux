import CmuxNextSettings
import Testing

/// `agentPane.vimMode`: vim editing in the agent chat composer, off by default. It reaches the page
/// on the `composer` event (webviews composerSettings.ts, composerVim.ts).
struct AgentPaneVimModeSettingTests {
    @Test func offByDefault() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.vimMode == false)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["vimMode"])?.boolValue == false)
        #expect(SettingsSchema.descriptor(for: AgentPaneComposerSetting.vimModePath)?.defaultValue == .bool(false))
    }

    @Test func onReachesThePage() {
        let root = JSONValue.object(["agentPane": .object(["vimMode": .bool(true)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.vimMode)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["vimMode"])?.boolValue == true)
        #expect(!snapshot.diagnostics.contains { $0.path.hasPrefix("agentPane.") })
    }

    @Test func aBadValueIsOffWithADiagnostic() {
        let root = JSONValue.object(["agentPane": .object(["vimMode": .string("on")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.vimMode == false)
        #expect(snapshot.diagnostics.contains { $0.path == "agentPane.vimMode" })
    }

    @Test func agentsMaySetIt() {
        #expect(SettingsSchema.agentSettableKeys.contains("agentPane.vimMode"))
        #expect(SettingsSchema.agentRefusedKeys["agentPane.vimMode"] == nil)
    }
}
