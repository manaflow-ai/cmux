import CmuxNextSettings
import Testing

/// `home.chiefChatIMessageStyle`: the Chief chat's bubbles take the theme's colours until the person
/// (or an agent: it is looks only) turns on iMessage's in Settings > Agents > Chief Chat or cmux.json.
struct ChiefChatStyleSettingTests {
    @Test func offByDefault() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.homeChiefChatIMessageStyle == false)
        let row = SettingsSchema.descriptor(for: HomeChiefChatStyleSetting.configPath)
        #expect(row?.defaultValue == .bool(false), "the Settings row's default is the parser's")
        #expect(row?.section == .home)
        #expect(row?.kind == .toggle)
    }

    @Test func cmuxJSONTurnsItOn() {
        let root = JSONValue.object(["home": .object(["chiefChatIMessageStyle": .bool(true)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.homeChiefChatIMessageStyle)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func aValueThatIsNotABoolIsOffWithADiagnostic() {
        let root = JSONValue.object(["home": .object(["chiefChatIMessageStyle": .string("yes")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.homeChiefChatIMessageStyle == false)
        #expect(snapshot.diagnostics.contains { $0.path == "home.chiefChatIMessageStyle" })
    }

    @Test func agentsMaySetIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: HomeChiefChatStyleSetting.configPath))
        #expect(SettingsSchema.agentSettable(row) == true)
        #expect(SettingsSchema.agentRefusedKeys[HomeChiefChatStyleSetting.key] == nil)
    }

    @Test func theSettingsPageDrawsItInAgents() throws {
        let agents = try #require(SettingsPageLayout().categories().first { $0.spec.id == "agents" })
        #expect(agents.groups.contains { $0.rows.contains(HomeChiefChatStyleSetting.key) })
    }
}
