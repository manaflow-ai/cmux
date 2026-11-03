import CmuxNextSettings
import Testing

/// `home.chiefEngine` (Leo's list 89(3); #64 decided the default): which Chief Home opens. Auto is
/// this Mac's optchat-chief while it runs, else the Hosted Chief; This Mac and Hosted force one.
/// It is the Engine row that leads Settings > Chief's Chiefs card, for everyone, not a Debug choice.
struct ChiefEngineSettingTests {
    @Test func theEngineIsAutoThisMacOrHostedAutoByDefault() throws {
        let row = try #require(SettingsSchema.descriptor(for: HomeChiefEngineSetting.configPath))
        #expect(row.defaultValue == .string("auto"))
        guard case .choice(let choices) = row.kind else {
            Issue.record("the Engine row is a choice")
            return
        }
        #expect(choices.map(\.value) == ["auto", "local", "hosted"])
        #expect(choices.map(\.title) == ["Auto", "This Mac", "Hosted"])
        #expect(row.title == "Engine")
        #expect(CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: []).homeChiefEngine == "auto")
    }

    @Test func aChoiceThatIsNotAnEngineIsAutoPlusADiagnostic() {
        let hosted = JSONValue.object(["home": .object(["chiefEngine": .string("hosted")])])
        #expect(CmuxConfigSnapshot.parse(hosted, validDensities: [], validMetrics: []).homeChiefEngine == "hosted")
        let bogus = JSONValue.object(["home": .object(["chiefEngine": .string("cloud9")])])
        let parsed = CmuxConfigSnapshot.parse(bogus, validDensities: [], validMetrics: [])
        #expect(parsed.homeChiefEngine == "auto")
        #expect(parsed.diagnostics.contains { $0.path == "home.chiefEngine" })
    }

    /// Where the person's Chief runs decides where their messages go (this Mac or the cloud), so
    /// only the person changes it, as with `home.server`.
    @Test func onlyThePersonPicksTheEngine() throws {
        let row = try #require(SettingsSchema.descriptor(for: HomeChiefEngineSetting.configPath))
        #expect(SettingsSchema.agentSettable(row) == false)
        #expect(SettingsSchema.agentRefusedKeys["home.chiefEngine"] == .privacy)
    }

    @Test func itIsOnTheChiefPage() throws {
        let chief = try #require(SettingsPageLayout().categories().first { $0.spec.id == "chief" })
        #expect(chief.groups.flatMap(\.rows).contains("home.chiefEngine"))
    }
}
