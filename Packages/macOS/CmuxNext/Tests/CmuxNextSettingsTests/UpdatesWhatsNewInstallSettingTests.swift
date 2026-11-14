import CmuxNextSettings
import Testing

/// `updates.whatsNewInstall`: off by default (What's New lists versions without Install until a
/// nightly proves it, cmux#36375); the person turns it on in Settings > General > Updates. Only the
/// person may: on, one click on What's New restarts cmux into another build.
struct UpdatesWhatsNewInstallSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["updates": .object(["whatsNewInstall": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        #expect(!Self.parse(nil).updates.whatsNewInstall)
        #expect(!UpdatesSettings.whatsNewInstallDefault)
    }

    @Test func thePersonCanTurnItOn() {
        #expect(Self.parse(.bool(true)).updates.whatsNewInstall)
        #expect(!Self.parse(.bool(false)).updates.whatsNewInstall)
    }

    @Test func settingsListsItAndAgentsMayNotSetIt() throws {
        let row = try #require(SettingsSchema.all.first { $0.path == UpdatesSettings.whatsNewInstallPath }, "Settings has no row")
        #expect(row.defaultValue == .bool(false))
        #expect(SettingsSchema.agentRefusedKeys["updates.whatsNewInstall"] == .userOnly)
        #expect(SettingsSchema.agentSettable(row) == false)
    }
}
