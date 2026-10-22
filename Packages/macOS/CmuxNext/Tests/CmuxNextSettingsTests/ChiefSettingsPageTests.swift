import CmuxNextSettings
import Testing

/// Settings has a Chief page (Leo 2026-10-20: "only having it as a popover is kind of crappy;
/// there's a lot of settings you may or may not want for the chief"). It holds every Chief
/// setting: the Chiefs list (each Chief's name, picture and backend), Chief Chat and Chief Pet.
/// Before, they sat at the bottom of Agents, and the sidebar had no Chief entry.
struct ChiefSettingsPageTests {
    static let chiefRows = [HomeChiefBubbleStyleSetting.key, "home.chiefPetEnabled", "home.chiefPetMascot"]

    @Test func settingsHasAChiefPageWithEveryChiefSetting() throws {
        let categories = SettingsPageLayout().categories()
        let chief = try #require(categories.first { $0.spec.id == "chief" }, "the sidebar has a Chief entry")
        #expect(chief.spec.lead == [.chiefs, .chiefPet, .voiceInput],
                "the Chiefs list opens the page, then the pet card, then Voice input (only where home.voiceInput exists)")
        let rows = chief.groups.flatMap(\.rows)
        for key in Self.chiefRows { #expect(rows.contains(key), "\(key) is on the Chief page") }
    }

    @Test func agentsNoLongerHoldsTheChief() throws {
        let agents = try #require(SettingsPageLayout().categories().first { $0.spec.id == "agents" })
        let rows = agents.groups.flatMap(\.rows)
        for key in Self.chiefRows { #expect(!rows.contains(key), "\(key) moved to Chief") }
        #expect(!(agents.spec.lead + agents.spec.trail).contains(.chiefs))
    }

    @Test func chiefComesRightAfterAgents() throws {
        let ids = SettingsPageLayout().categories().map(\.spec.id)
        let agents = try #require(ids.firstIndex(of: "agents"))
        #expect(ids.dropFirst(agents + 1).first == "chief")
    }
}
