import CmuxNextSettings
import Testing

/// `developerTools.overloadNotice`: Settings > Advanced > Developer Tools turns the agent chat's
/// "This Mac is overloaded" banner on. Off by default (https://github.com/manaflow-ai/cmux/issues/56156).
struct HostOverloadNoticeSettingTests {
    @Test func theRowIsInAdvancedAndOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["developerTools", "overloadNotice"]))
        #expect(descriptor.section == .advanced)
        #expect(descriptor.kind == .toggle)
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.isShownOnSettingsPage)
    }

    @Test func theComposerEventCarriesItOffByDefault() {
        #expect(HostOverloadNoticeSetting().value(in: .object([:])) == false)
        #expect(AgentPaneComposerSetting.fallback.showOverloadNotice == false)
        #expect(AgentPaneComposerSetting.fallback.pageValue.value(at: ["showOverloadNotice"])?.boolValue == false)
    }

    @Test func aLiteralTrueTurnsItOn() {
        let on = JSONValue.object(["developerTools": .object(["overloadNotice": .bool(true)])])
        #expect(HostOverloadNoticeSetting().value(in: on))
        #expect(CmuxConfigSnapshot.parse(on, validDensities: [], validMetrics: []).agentPaneComposer.showOverloadNotice)
        let text = JSONValue.object(["developerTools": .object(["overloadNotice": .string("true")])])
        #expect(CmuxConfigSnapshot.parse(text, validDensities: [], validMetrics: []).agentPaneComposer.showOverloadNotice == false)
    }
}
