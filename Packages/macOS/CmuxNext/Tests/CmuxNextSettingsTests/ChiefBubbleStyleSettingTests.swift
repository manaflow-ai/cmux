import CmuxNextSettings
import Testing

/// `home.chiefBubbleStyle`: the Chief chat's bubbles are iMessage's (the default) until the person, or
/// an agent (it is looks only), picks Theme in Settings > Chief > Chief Chat or cmux.json.
struct ChiefBubbleStyleSettingTests {
    @Test func iMessageByDefault() throws {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.homeChiefBubbleStyle == "imessage")
        let row = try #require(SettingsSchema.descriptor(for: HomeChiefBubbleStyleSetting.configPath))
        #expect(row.defaultValue == .string("imessage"), "the Settings row's default is the parser's")
        #expect(row.section == .home)
        if case .choice(let choices) = row.kind {
            #expect(choices.map(\.value) == ["imessage", "theme"])
        } else {
            Issue.record("the bubble style row is a choice")
        }
    }

    @Test func cmuxJSONPicksTheTheme() {
        let root = JSONValue.object(["home": .object(["chiefBubbleStyle": .string("theme")])])
        let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
        #expect(snapshot.homeChiefBubbleStyle == "theme")
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func anUnknownStyleIsIMessageWithADiagnostic() {
        for value in [JSONValue.string("blue"), .bool(true)] {
            let root = JSONValue.object(["home": .object(["chiefBubbleStyle": value])])
            let snapshot = CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
            #expect(snapshot.homeChiefBubbleStyle == "imessage")
            #expect(snapshot.diagnostics.contains { $0.path == "home.chiefBubbleStyle" })
        }
    }

    @Test func agentsMaySetIt() throws {
        let row = try #require(SettingsSchema.descriptor(for: HomeChiefBubbleStyleSetting.configPath))
        #expect(SettingsSchema.agentSettable(row) == true)
        #expect(SettingsSchema.agentRefusedKeys[HomeChiefBubbleStyleSetting.key] == nil)
    }

    @Test func theSettingsPageDrawsItInChief() throws {
        let chief = try #require(SettingsPageLayout().categories().first { $0.spec.id == "chief" })
        #expect(chief.groups.contains { $0.rows.contains(HomeChiefBubbleStyleSetting.key) })
    }
}
