import CmuxNextSettings
import Testing

/// `appearance.agentGlow`: off by default, because it changes the default look (Leo: "some of
/// them maybe just as customizations lol if it affects default looks"); on, it is one toggle in
/// Appearance.
struct AgentGlowSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        var root: [String: JSONValue] = [:]
        if let value { root["appearance"] = .object(["agentGlow": value]) }
        return CmuxConfigSnapshot.parse(.object(root), validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.agentGlow == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOn() {
        #expect(Self.parse(.bool(true)).agentGlow)
        #expect(Self.parse(.bool(false)).agentGlow == false)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.agentGlow == false)
        #expect(snapshot.diagnostics.contains { $0.path == "appearance.agentGlow" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOffInAppearance() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["appearance", "agentGlow"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .appearance)
        #expect(descriptor.kind == .toggle)
        #expect(SettingsSchema.agentSettableKeys.contains("appearance.agentGlow"))
    }
}
