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

    /// The pet is a display the person can hide again, so an agent may turn it on or off as well
    /// as pick its character. Its reply box still types only what the person writes.
    @Test func agentsMayTurnItOnAndPickTheCharacter() throws {
        let enabled = try #require(SettingsSchema.descriptor(for: HomeChiefPetSetting.configPath))
        #expect(SettingsSchema.agentSettable(enabled) == true)
        #expect(SettingsSchema.agentRefusedKeys["home.chiefPetEnabled"] == nil)
        let mascot = try #require(SettingsSchema.descriptor(for: HomeChiefPetSetting.mascotPath))
        #expect(SettingsSchema.agentSettable(mascot) == true)
    }

    @Test func characterIsOneOfTheDockMascotsOrbByDefault() {
        let empty = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(empty.homeChiefPetMascot == "orb")
        let fox = JSONValue.object(["home": .object(["chiefPetMascot": .string("fox")])])
        #expect(CmuxConfigSnapshot.parse(fox, validDensities: [], validMetrics: []).homeChiefPetMascot == "fox")
        let dog = JSONValue.object(["home": .object(["chiefPetMascot": .string("dog")])])
        let parsed = CmuxConfigSnapshot.parse(dog, validDensities: [], validMetrics: [])
        #expect(parsed.homeChiefPetMascot == "orb")
        #expect(parsed.diagnostics.contains { $0.path == "home.chiefPetMascot" })
        let row = SettingsSchema.descriptor(for: HomeChiefPetSetting.mascotPath)
        #expect(row?.defaultValue == .string("orb"))
        if case .choice(let choices) = row?.kind {
            #expect(choices.map(\.value) == HomeChiefPetSetting.mascots)
        } else {
            Issue.record("the character row is a choice")
        }
    }
}
