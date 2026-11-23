import CmuxNextSettings
import Testing

/// `agentPane.autoChatPlacement` (Settings > Agent Chat > Auto Chat Placement): on by default (decided by debate, RFD
/// 0057, d-94bef9b79e), so a new chat's place picker offers Auto until the person turns it off. It reaches the page on the
/// `composer` event (webviews composerSettings.ts, autoPlace.ts).
struct AgentPaneAutoChatPlacementSettingTests {
    @Test func onByDefaultAndOnThePage() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.autoChatPlacement == true)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["autoChatPlacement"])?.boolValue == true)
        let row = SettingsSchema.descriptor(for: AgentPaneComposerSetting.autoChatPlacementPath)
        #expect(row?.defaultValue == .bool(true))
    }

    @Test func offRoundTrips() {
        let root = JSONValue.object(["agentPane": .object(["autoChatPlacement": .bool(false)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.autoChatPlacement == false)
        #expect(snapshot.agentPaneComposer.pageValue.value(at: ["autoChatPlacement"])?.boolValue == false)
        #expect(!snapshot.diagnostics.contains { $0.path == "agentPane.autoChatPlacement" })
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let root = JSONValue.object(["agentPane": .object(["autoChatPlacement": .string("off")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneComposer.autoChatPlacement == true)
        #expect(snapshot.diagnostics.contains { $0.path == "agentPane.autoChatPlacement" })
    }
}
