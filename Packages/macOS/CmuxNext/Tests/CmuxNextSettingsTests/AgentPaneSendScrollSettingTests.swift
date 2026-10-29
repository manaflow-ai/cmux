import CmuxNextSettings
import Testing

/// The send-scroll choice is a user setting: it is on by default, reaches the web composer event,
/// and is exposed to both the Settings page and the generic command-palette setting picker.
struct AgentPaneSendScrollSettingTests {
    @Test func onByDefaultAndOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.scrollToBottomOnSend)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["scrollToBottomOnSend"])?.boolValue == true)
        let row = SettingsSchema.descriptor(for: AgentPaneComposerSetting.scrollToBottomOnSendPath)
        #expect(row?.defaultValue == .bool(true))
        #expect(row?.isPaletteExposed == true)
    }

    @Test func offRoundTripsAndStaysUserOnly() {
        let root = JSONValue.object(["agentPane": .object(["scrollToBottomOnSend": .bool(false)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.scrollToBottomOnSend == false)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["scrollToBottomOnSend"])?.boolValue == false)
        #expect(SettingsSchema.agentRefusedKeys["agentPane.scrollToBottomOnSend"] == .userOnly)
        #expect(!SettingsSchema.agentSettableKeys.contains("agentPane.scrollToBottomOnSend"))
    }
}
