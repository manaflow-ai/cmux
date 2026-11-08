import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Issue 38169: the Chief chat and the agent chats zoomed together, because Cmd-= / Cmd-- / Cmd-0 on Home
/// stepped Agent Chat Zoom (`agentPane.zoom`). The Chief chat now has its own setting, `home.chiefZoom`
/// (Settings > Chief > Look, cmux.json, agents), read and applied apart from the agent chats' zoom.
@MainActor
struct ChiefZoomSettingTests {
    @Test func eachChatKeepsItsOwnZoom() {
        let root = JSONValue.object([
            "home": .object(["chiefZoom": .number(1.4)]),
            "agentPane": .object(["zoom": .number(0.8)]),
        ])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.homeChiefZoom == 1.4)
        #expect(snapshot.agentPaneZoom == 0.8)
        #expect(snapshot.diagnostics.isEmpty)

        let onlyAgent = CmuxConfigSnapshot.parse(.object(["agentPane": .object(["zoom": .number(1.6)])]),
                                                 validDensities: [], validMetrics: [])
        #expect(onlyAgent.homeChiefZoom == HomeChiefZoomSetting.fallback, "Agent Chat Zoom no longer sizes the Chief chat")
    }

    @Test func applyingSettingsMovesOnlyTheChatThatChanged() {
        let design = DesignSettings()
        let root = JSONValue.object([
            "home": .object(["chiefZoom": .number(1.3)]),
            "agentPane": .object(["zoom": .number(0.9)]),
        ])
        let applier = SettingsApplier(design: design, registry: ActionRegistry())
        _ = applier.apply(CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: []))
        #expect(abs(design.homeChiefZoom - 1.3) < 1e-9)
        #expect(abs(design.agentPaneZoom - 0.9) < 1e-9)
        // Zooming agent chats again leaves the Chief chat where it was.
        _ = applier.apply(CmuxConfigSnapshot.parse(.object(["home": .object(["chiefZoom": .number(1.3)]),
                                                            "agentPane": .object(["zoom": .number(1.5)])]),
                                                   validDensities: [], validMetrics: []))
        #expect(abs(design.homeChiefZoom - 1.3) < 1e-9)
        #expect(abs(design.agentPaneZoom - 1.5) < 1e-9)
    }

    @Test func anOutOfRangeZoomIsClampedWithADiagnostic() {
        for (value, expected) in [(JSONValue.number(9), 2.0), (.number(0.1), 0.5), (.string("big"), 1.0)] {
            let snapshot = CmuxConfigSnapshot.parse(.object(["home": .object(["chiefZoom": value])]),
                                                    validDensities: [], validMetrics: [])
            #expect(snapshot.homeChiefZoom == expected)
            #expect(snapshot.diagnostics.contains { $0.path == "home.chiefZoom" })
        }
    }

    @Test func theSettingsPageDrawsItInChiefAndAgentsMaySetIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: HomeChiefZoomSetting.configPath))
        #expect(row.defaultValue == .number(HomeChiefZoomSetting.fallback))
        #expect(SettingsSchema.agentSettable(row) == true)
        let chief = try #require(SettingsPageLayout().categories().first { $0.spec.id == "chief" })
        #expect(chief.groups.contains { $0.rows.contains("home.chiefZoom") })
        let agentZoom = try #require(SettingsSchema.descriptor(for: AgentPaneZoomSetting.configPath))
        #expect(agentZoom.title != row.title, "two settings, two titles")
    }
}
