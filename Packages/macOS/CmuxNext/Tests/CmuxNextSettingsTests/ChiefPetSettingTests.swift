import CmuxNextSettings
import Testing

/// `home.chiefPetEnabled`: the floating Chief pet is off until the person (or an agent: it is looks
/// only) turns it on in Settings > Home, the palette's settings rows or `cmux settings set`.
struct ChiefPetSettingTests {
    @Test func offByDefault() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.homeChiefPetEnabled == false)
        let row = SettingsSchema.descriptor(for: HomeChiefPetSetting.configPath)
        #expect(row?.defaultValue == .bool(false), "the Settings row's default is the parser's")
        #expect(row?.section == .home)
        #expect(row?.kind == .toggle)
    }

    @Test func cmuxJSONTurnsItOn() {
        let root = JSONValue.object(["home": .object(["chiefPetEnabled": .bool(true)])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.homeChiefPetEnabled)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func aValueThatIsNotABoolIsOffWithADiagnostic() {
        let root = JSONValue.object(["home": .object(["chiefPetEnabled": .string("yes")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.homeChiefPetEnabled == false)
        #expect(snapshot.diagnostics.contains { $0.path == "home.chiefPetEnabled" })
    }

    @Test func agentsMaySetIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: HomeChiefPetSetting.configPath))
        #expect(SettingsSchema.agentSettable(row) == true)
    }
}
