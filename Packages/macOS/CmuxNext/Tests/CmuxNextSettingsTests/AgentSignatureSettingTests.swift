import CmuxNextSettings
import Testing

/// `appearance.agentSignature`: each agent's dot glyph changes the default look, so it is a
/// customization that stays off unless the person turns it on (Leo: "some of them maybe just as
/// customizations lol if it affects default looks").
struct AgentSignatureSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let appearance: [String: JSONValue] = value.map { ["agentSignature": $0] } ?? [:]
        return CmuxConfigSnapshot.parse(.object(["appearance": .object(appearance)]), validDensities: [], validMetrics: [])
    }

    @Test func offByDefaultWithAToggle() {
        let snapshot = Self.parse(nil)
        #expect(!snapshot.agentSignature)
        #expect(snapshot.diagnostics.isEmpty)
        #expect(!AgentSignatureSetting.fallback)
        let descriptor = SettingsSchema.descriptor(for: AgentSignatureSetting.configPath)
        #expect(descriptor?.defaultValue == .bool(false))
        #expect(AgentSignatureSetting.configPath == ["appearance", "agentSignature"])
    }

    @Test func trueTurnsItOn() {
        #expect(Self.parse(.bool(true)).agentSignature)
        #expect(!Self.parse(.bool(false)).agentSignature)
    }

    @Test func aBadValueKeepsItOffAndSaysSo() {
        let snapshot = Self.parse(.string("on"))
        #expect(!snapshot.agentSignature)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.agentSignature" })
    }
}
