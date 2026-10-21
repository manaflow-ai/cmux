import CmuxNextSettings
import Testing

/// `sessions.keepAwake`: idle sleep stays off while an agent works on adapter
/// power by default; off and always are the other choices. Only the person sets it.
struct SessionKeepAwakeSettingTests {
    private static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sessions": .object(["keepAwake": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func whilePluggedInWhenUnset() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sessions.keepAwake == .pluggedIn)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: [("off", SessionKeepAwakeSetting.off), ("pluggedIn", .pluggedIn), ("always", .always)])
    func eachChoiceLoads(raw: String, expected: SessionKeepAwakeSetting) {
        #expect(Self.parse(.string(raw)).sessions.keepAwake == expected)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("forever"))
        #expect(snapshot.sessions.keepAwake == .pluggedIn)
        #expect(snapshot.diagnostics.contains { $0.path == "sessions.keepAwake" })
    }

    @Test func theRowMatchesTheAppAndAgentsMayNotSetIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: ["sessions", "keepAwake"]))
        #expect(row.defaultValue == .string("pluggedIn"))
        #expect(SettingsSchema.agentRefusedKeys["sessions.keepAwake"] == .userOnly)
        #expect(!SettingsSchema.agentSettableKeys.contains("sessions.keepAwake"))
    }

    @Test func theRowShowsUnderAgents() throws {
        let agents = try #require(SettingsPageLayout().categories().first { $0.spec.id == "agents" })
        #expect(agents.groups.contains { $0.rows.contains("sessions.keepAwake") })
    }
}
