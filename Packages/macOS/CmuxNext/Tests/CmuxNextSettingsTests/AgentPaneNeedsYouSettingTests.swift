import CmuxNextSettings
import Testing

/// `agentPane.needsYou.enabled`: Needs you in the agent chat header is an App Store item, off until
/// the person (or an agent: it is looks only) gets it (Leo 2026-10-22: "app store maybe?").
struct AgentPaneNeedsYouSettingTests {
    @Test func offByDefault() throws {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.agentPaneNeedsYouEnabled == false)
        let row = try #require(SettingsSchema.descriptor(for: AgentPaneNeedsYouSetting.enabledPath))
        #expect(row.id == "agentPane.needsYou.enabled")
        #expect(row.defaultValue == .bool(false), "the Settings row's default is the reader's")
        #expect(row.kind == .toggle)
        #expect(SettingsSchema.agentSettable(row) == true)
    }

    @Test func cmuxJSONTurnsItOn() {
        let root = JSONValue.object(["agentPane": .object(["needsYou": .object(["enabled": .bool(true)])])])
        #expect(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).agentPaneNeedsYouEnabled)
    }

    @Test func aValueThatIsNotABoolIsOff() {
        let root = JSONValue.object(["agentPane": .object(["needsYou": .object(["enabled": .string("yes")])])])
        #expect(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []).agentPaneNeedsYouEnabled == false)
    }
}
