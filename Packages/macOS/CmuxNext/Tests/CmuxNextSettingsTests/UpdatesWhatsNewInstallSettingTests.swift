import CmuxNextSettings
import Testing

/// `updates.whatsNewInstall`: on by default (Leo 2026-11-05: "Like literally with a click to a past
/// nightly", cmux#36375); the person can turn it off in Settings > General > Updates. Only the
/// person may change it: on, one click on What's New restarts cmux into another build.
struct UpdatesWhatsNewInstallSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["updates": .object(["whatsNewInstall": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func onByDefault() {
        #expect(Self.parse(nil).updates.whatsNewInstall)
        #expect(UpdatesSettings.whatsNewInstallDefault)
    }

    @Test func thePersonCanTurnItOff() {
        #expect(Self.parse(.bool(true)).updates.whatsNewInstall)
        #expect(!Self.parse(.bool(false)).updates.whatsNewInstall)
    }

    @Test func settingsListsItAndAgentsMayNotSetIt() throws {
        let row = try #require(SettingsSchema.all.first { $0.path == UpdatesSettings.whatsNewInstallPath }, "Settings has no row")
        #expect(row.defaultValue == .bool(true))
        #expect(SettingsSchema.agentRefusedKeys["updates.whatsNewInstall"] == .userOnly)
        #expect(SettingsSchema.agentSettable(row) == false)
    }
}
