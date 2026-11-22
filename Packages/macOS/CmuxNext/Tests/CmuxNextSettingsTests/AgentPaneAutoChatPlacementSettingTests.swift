import CmuxNextSettings
import Testing

/// `agentPane.autoChatPlacement` (Settings > Agent Chat > Auto Chat Placement): off by default, so a
/// new chat's place picker is as before until the person turns it on. It reaches the page on the
/// `composer` event (webviews composerSettings.ts, autoPlace.ts).
struct AgentPaneAutoChatPlacementSettingTests {
    @Test func offByDefaultAndOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.autoChatPlacement == false)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["autoChatPlacement"])?.boolValue == false)
        let row = SettingsSchema.descriptor(for: AgentPaneComposerSetting.autoChatPlacementPath)
        #expect(row?.defaultValue == .bool(false))
    }

    @Test func onRoundTrips() {
        let root = JSONValue.object(["agentPane": .object(["autoChatPlacement": .bool(true)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.autoChatPlacement == true)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["autoChatPlacement"])?.boolValue == true)
        #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.autoChatPlacement" })
    }

    @Test func aBadValueIsOffWithADiagnostic() {
        let root = JSONValue.object(["agentPane": .object(["autoChatPlacement": .string("on")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.autoChatPlacement == false)
        #expect(snapshot.diagnostics.contains { $0.path == "agentPane.autoChatPlacement" })
    }
}
